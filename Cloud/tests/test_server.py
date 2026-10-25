import base64
import http.client
import json
import tempfile
import threading
import time
import unittest
from http.cookies import SimpleCookie
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import CloudHTTPServer, Store

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1kAAAAASUVORK5CYII=')
OWNER = 'unit-test-owner-token'

class CloudTests(unittest.TestCase):
    def test_restarting_does_not_restore_rotated_owner_token(self):
        from server import digest
        with self.store.db() as db:
            db.execute("UPDATE users SET token_hash=? WHERE id='admin'", (digest('rotated-secret'),))
        restarted = Store(Path(self.temp.name), self.store.public_url, admin_token=OWNER)
        with restarted.db() as db:
            self.assertEqual(db.execute("SELECT token_hash FROM users WHERE id='admin'").fetchone()[0], digest('rotated-secret'))

    def test_bundled_server_cli_publishes_private_readiness_file(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); ready = folder/'ready.json'
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parents[1]/'server.py'), '--port', '0', '--data', str(folder/'data'), '--ready-file', str(ready)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if ready.exists(): break
                    if process.poll() is not None: self.fail('Server exited before becoming ready')
                    time.sleep(0.05)
                info = json.loads(ready.read_text())
                self.assertEqual(info['pid'], process.pid)
                self.assertEqual(ready.stat().st_mode & 0o777, 0o600)
                self.assertEqual((folder/'data').stat().st_mode & 0o777, 0o700)
                connection = http.client.HTTPConnection('127.0.0.1', info['port'], timeout=3)
                connection.request('GET', '/api/health'); response = connection.getresponse()
                self.assertEqual(response.status, 200); response.read(); connection.close()
            finally:
                process.terminate(); process.wait(timeout=5)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name), 'http://127.0.0.1', admin_token=OWNER)
        self.server = CloudHTTPServer(('127.0.0.1', 0), self.store)
        self.store.public_url = f'http://127.0.0.1:{self.server.server_port}'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()
    def call(self, method, path, data=None, auth=OWNER, jar=None, headers=None):
        request_headers = {}
        if auth: request_headers['Authorization'] = 'Bearer '+auth
        if jar: request_headers['Cookie'] = '; '.join(k+'='+v for k,v in jar.items())
        if isinstance(data, dict): data = json.dumps(data).encode(); request_headers['Content-Type'] = 'application/json'
        if headers: request_headers.update(headers)
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=10)
        connection.request(method, path, body=data, headers=request_headers)
        response = connection.getresponse(); body = response.read(); result_headers = dict(response.getheaders())
        if jar is not None:
            for key,value in response.getheaders():
                if key.lower() == 'set-cookie':
                    cookie = SimpleCookie(); cookie.load(value)
                    for name,morsel in cookie.items(): jar[name] = morsel.value
        status = response.status; connection.close()
        if result_headers.get('Content-Type','').startswith(('application/json','application/scim')): body = json.loads(body) if body else {}
        return status, body, result_headers
    def create(self, **options):
        data = dict(title='A test capture', mime='image/png', size=len(PNG), expiryDays=7, tags=['Design']); data.update(options)
        status, item, _ = self.call('POST', '/api/uploads', data)
        self.assertEqual(status, 201, item)
        status, stored, _ = self.call('PUT', f"/api/uploads/{item['id']}/content", PNG, headers={'Content-Type':'image/png'})
        self.assertEqual(status, 200, stored)
        return stored
    def test_auth_upload_range_and_type_validation(self):
        self.assertEqual(self.call('GET','/api/me', auth=None)[0],401)
        item=self.create()
        status, content, headers=self.call('GET',item['media'],auth=None,headers={'Range':'bytes=0-7'})
        self.assertEqual(status,206); self.assertEqual(content,PNG[:8]); self.assertEqual(headers['Content-Range'], f'bytes 0-7/{len(PNG)}')
        self.assertEqual(self.call('HEAD',item['media'],auth=None)[0],200)
        self.assertEqual(self.call('GET',item['media'],auth=None,headers={'Range':'bytes=9999-10000'})[0],416)
        self.assertEqual(self.call('GET','/static/../../server.py',auth=None)[0],404)
        _, pending, _ = self.call('POST','/api/uploads', dict(title='Bad',mime='image/png',size=5))
        self.assertEqual(self.call('PUT',f"/api/uploads/{pending['id']}/content",b'<svg>')[0],400)
        self.assertEqual(self.call('POST','/api/uploads',dict(title='Bad',mime='text/html',size=10))[0],400)
    def test_password_expiry_and_owner_download(self):
        item=self.create(password='test-password')
        self.assertEqual(self.call('GET',f"/api/share/{item['token']}",auth=None)[0],401)
        jar={}
        self.assertEqual(self.call('POST',f"/api/share/{item['token']}/unlock",dict(password='wrong'),auth=None,jar=jar)[0],401)
        self.assertEqual(self.call('POST',f"/api/share/{item['token']}/unlock",dict(password='test-password'),auth=None,jar=jar)[0],200)
        self.assertEqual(self.call('GET',f"/api/share/{item['token']}",auth=None,jar=jar)[0],200)
        self.assertEqual(self.call('GET',item['media'],auth=None,jar=jar)[0],200)
        with self.store.db() as db: db.execute('UPDATE uploads SET expires=? WHERE id=?',(time.time()-1,item['id']))
        self.assertEqual(self.call('GET',item['media'],auth=None,jar=jar)[0],410)
        self.assertEqual(self.call('GET',item['download'])[0],200)
    def test_view_limit_requires_share_visit_and_allows_existing_viewer(self):
        item=self.create(maxViews=1)
        self.assertEqual(self.call('GET',item['media'],auth=None)[0],403)
        jar={}
        self.assertEqual(self.call('GET',f"/api/share/{item['token']}",auth=None,jar=jar)[0],200)
        self.assertEqual(self.call('GET',item['media'],auth=None,jar=jar)[0],200)
        self.assertEqual(self.call('GET',f"/api/share/{item['token']}",auth=None)[0],410)
        self.assertEqual(self.call('GET',item['media'],auth=None,jar=jar)[0],200)
    def test_private_team_and_cross_account_permissions(self):
        _, user, _=self.call('POST','/api/users',dict(username='member@example.test',name='Member'))
        member=user['token']; private=self.create(visibility='private'); team=self.create(visibility='team')
        self.assertEqual(self.call('GET',f"/api/share/{private['token']}",auth=member)[0],401)
        self.assertEqual(self.call('GET',f"/api/share/{team['token']}",auth=None)[0],401)
        self.assertEqual(self.call('GET',f"/api/share/{team['token']}",auth=member)[0],200)
        self.assertEqual(self.call('DELETE',f"/api/uploads/{private['id']}",auth=member)[0],404)
        self.assertEqual(self.call('GET','/api/users',auth=member)[0],403)
        self.assertEqual(self.call('GET','/api/uploads',auth=member)[1]['total'],0)
    def test_cookie_csrf_origin_and_token_rotation(self):
        jar={}
        self.assertEqual(self.call('POST','/api/login',dict(token=OWNER),auth=None,jar=jar)[0],200)
        csrf=self.call('GET','/api/me',auth=None,jar=jar)[1]['csrf']
        data=dict(title='Cookie capture',mime='image/png',size=len(PNG))
        self.assertEqual(self.call('POST','/api/uploads',data,auth=None,jar=jar)[0],403)
        self.assertEqual(self.call('POST','/api/uploads',data,auth=None,jar=jar,headers={'X-CSRF-Token':csrf,'Origin':'https://not-the-server.test'})[0],403)
        self.assertEqual(self.call('POST','/api/uploads',data,auth=None,jar=jar,headers={'X-CSRF-Token':csrf,'Origin':self.store.public_url})[0],201)
        _, result, _=self.call('POST','/api/token',{})
        self.assertEqual(self.call('GET','/api/me',auth=OWNER)[0],401)
        self.assertEqual(self.call('GET','/api/me',auth=result['token'])[0],200)
    def test_comments_reply_resolve_and_untrusted_text_round_trip(self):
        item=self.create(); jar={}
        _, share, _=self.call('GET',f"/api/share/{item['token']}",auth=None,jar=jar)
        text='<script>alert("not HTML")</script>'
        data=dict(author='Test Guest',text=text,x=.4,y=.6,seconds=1.5)
        self.assertEqual(self.call('POST',f"/api/share/{item['token']}/comments",data,auth=None,jar=jar)[0],403)
        _, comment, _=self.call('POST',f"/api/share/{item['token']}/comments",data,auth=None,jar=jar,headers={'X-Share-CSRF':share['csrf']})
        self.assertIn('id',comment)
        self.assertEqual(self.call('POST',f"/api/share/{item['token']}/comments",dict(text='Reply',parentId=comment['id']))[0],403) # Missing viewer context is rejected.
        status, comments, _=self.call('GET',f"/api/share/{item['token']}/comments",auth=None,jar=jar)
        self.assertEqual(status,200); self.assertEqual(comments['comments'][0]['text'],text)
        self.assertEqual(self.call('PATCH',f"/api/comments/{comment['id']}",dict(resolved=True))[0],200)
        self.assertTrue(self.call('GET',f"/api/share/{item['token']}/comments",auth=None,jar=jar)[1]['comments'][0]['resolved'])
    def test_search_pagination_trash_restore_and_audit(self):
        a=self.create(title='First image',ocr='unusual OCR word',transcript='A searchable transcript')
        self.create(title='Second image')
        result=self.call('GET','/api/uploads?count=1')[1]
        self.assertEqual(result['total'],2); self.assertEqual(len(result['items']),1); self.assertEqual(result['nextOffset'],1)
        self.assertEqual(self.call('GET','/api/uploads?q=unusual')[1]['items'][0]['id'],a['id'])
        self.assertEqual(self.call('DELETE',f"/api/uploads/{a['id']}")[0],200)
        self.assertEqual(self.call('GET',a['media'],auth=None)[0],410)
        self.assertEqual(self.call('GET','/api/uploads?trash=1')[1]['total'],1)
        self.assertEqual(self.call('POST',f"/api/uploads/{a['id']}/restore",{})[0],200)
        self.assertEqual(self.call('GET',a['media'],auth=None)[0],200)
        self.assertGreater(len(self.call('GET','/api/audit')[1]['events']),4)
    def test_scim_provision_update_deactivate_and_owner_protection(self):
        self.store.scim_token='unit-test-scim'
        headers={'Authorization':'Bearer unit-test-scim'}
        self.assertEqual(self.call('GET','/scim/v2/Users',auth=None)[0],401)
        status,user,_=self.call('POST','/scim/v2/Users',dict(userName='person@example.test',displayName='Person',active=True),auth=None,headers=headers)
        self.assertEqual(status,201)
        self.assertEqual(self.call('PATCH','/scim/v2/Users/'+user['id'],dict(Operations=[dict(op='replace',path='active',value=False)]),auth=None,headers=headers)[0],200)
        self.assertFalse(self.call('GET','/scim/v2/Users/'+user['id'],auth=None,headers=headers)[1]['active'])
        self.assertEqual(self.call('DELETE','/scim/v2/Users/admin',auth=None,headers=headers)[0],403)
    def test_scim_group_membership_patch_filters_and_delete(self):
        self.store.scim_token = 'unit-test-scim'
        headers = {'Authorization': 'Bearer unit-test-scim'}
        status, user, _ = self.call('POST', '/scim/v2/Users', dict(userName='member@example.test'), auth=None, headers=headers)
        self.assertEqual(status, 201)
        status, group, _ = self.call('POST', '/scim/v2/Groups', dict(displayName='Design', externalId='design-team', members=[dict(value=user['id'])]), auth=None, headers=headers)
        self.assertEqual(status, 201); self.assertEqual(group['members'][0]['value'], user['id'])
        path = '/scim/v2/Groups/'+group['id']
        patch = dict(Operations=[dict(op='remove',path='members[value eq "'+user['id']+'"]')])
        self.assertEqual(self.call('PATCH', path, patch, auth=None, headers=headers)[1]['members'], [])
        patch = dict(Operations=[dict(op='add',path='members',value=[dict(value=user['id'])])])
        self.assertEqual(len(self.call('PATCH', path, patch, auth=None, headers=headers)[1]['members']), 1)
        self.assertEqual(self.call('GET','/scim/v2/Groups?filter=externalId%20eq%20%22design-team%22',auth=None,headers=headers)[1]['totalResults'], 1)
        self.assertEqual(self.call('PATCH',path,dict(Operations=[dict(op='add',path='members',value=[dict(value='unknown')])]),auth=None,headers=headers)[0],400)
        self.assertEqual(self.call('GET',path,auth=None)[0],401)
        self.assertEqual(self.call('DELETE',path,auth=None,headers=headers)[0],204)
        self.assertEqual(self.call('GET',path,auth=None,headers=headers)[0],404)

    def test_oidc_pkce_state_verified_email_and_subject_binding(self):
        import io, os
        from unittest.mock import patch
        from urllib.parse import urlsplit, parse_qs
        from server import b64
        import hashlib
        issuer = 'https://identity.example.test'
        identity = dict(sub='person-1', email='member@example.test', email_verified=True, name='Member')
        exchanges = []
        def fake_open(request, **kwargs):
            url = request if isinstance(request, str) else request.full_url
            if url.endswith('/.well-known/openid-configuration'):
                value = dict(issuer=issuer,authorization_endpoint=issuer+'/authorize',token_endpoint=issuer+'/token',userinfo_endpoint=issuer+'/userinfo')
            elif url.endswith('/token'):
                exchanges.append(parse_qs(request.data.decode())); value = dict(access_token='synthetic-access')
            elif url.endswith('/userinfo'): value = identity.copy()
            else: self.fail('Unexpected identity request')
            return io.BytesIO(json.dumps(value).encode())
        environment = dict(STILL_OIDC_ISSUER=issuer,STILL_OIDC_CLIENT_ID='test-client',STILL_OIDC_ALLOWED_DOMAINS='example.test')
        with patch.dict(os.environ,environment), patch('server.urlopen',side_effect=fake_open):
            jar = {}
            status, _, headers = self.call('GET','/auth/oidc',auth=None,jar=jar)
            self.assertEqual(status,302)
            params = parse_qs(urlsplit(headers['Location']).query)
            state = params['state'][0]
            self.assertEqual(self.call('GET','/auth/callback?code=test&state=wrong',auth=None,jar=jar)[0],403)
            self.assertEqual(exchanges,[])
            self.assertEqual(self.call('GET','/auth/callback?code=test&state='+state,auth=None,jar=jar)[0],302)
            self.assertEqual(b64(hashlib.sha256(exchanges[0]['code_verifier'][0].encode()).digest()),params['code_challenge'][0])
            self.assertEqual(self.call('GET','/api/me',auth=None,jar=jar)[1]['user']['name'],'Member')
            identity['sub'] = 'reassigned-person'
            self.call('GET','/auth/oidc',auth=None,jar=jar)
            saved = self.store.unsign(jar['still_oidc'])
            self.assertEqual(self.call('GET','/auth/callback?code=test&state='+saved['state'],auth=None,jar=jar)[0],403)
            identity.update(sub='person-2',email='unverified@example.test',email_verified=False)
            self.assertEqual(self.call('GET','/auth/callback?code=test&state='+saved['state'],auth=None,jar=jar)[0],403)

    def test_static_security_headers_and_invalid_values(self):
        status,css,headers=self.call('GET','/static/style.css',auth=None)
        self.assertEqual(status,200); self.assertNotIn(b'{{ACCENT}}',css); self.assertEqual(headers['X-Content-Type-Options'],'nosniff')
        self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        self.assertEqual(self.call('POST','/api/uploads',dict(size='not-a-number',mime='image/png'))[0],400)
        self.assertEqual(self.call('POST','/api/uploads',dict(size=float('nan'),mime='image/png'))[0],400)
        self.assertEqual(self.call('GET','/auth/oidc',auth=None)[0],503)

if __name__=='__main__': unittest.main()
