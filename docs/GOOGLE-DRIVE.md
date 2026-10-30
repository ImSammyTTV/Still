# Setting up Google Drive sharing

Still uploads to Google Drive with a sign-in client that belongs to the project. This only needs doing once, and only
by whoever publishes releases. People using Still just click **Connect**.

1. Open the [Google Cloud console](https://console.cloud.google.com/) and create a project called `Still`.
2. Under **APIs & Services → Library**, enable the **Google Drive API**.
3. Under **Google Auth Platform → Branding**, set the app name to `Still` and add a support email.
4. Under **Audience**, choose **External**, then press **Publish app**. This matters: while an app is in *Testing*,
   Google signs people out after 7 days and allows only listed test users.
5. Under **Data Access**, add the scope `https://www.googleapis.com/auth/drive.file`. It only reaches files Still
   created, so Google treats it as non-sensitive and it doesn't need a security review.
6. Under **Clients**, create a client of type **Desktop app**. Copy its **Client ID** and **Client secret**.
7. Add both to the repository under **Settings → Secrets and variables → Actions** as `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET`. The next release includes them.

For a local build, set `STILL_GOOGLE_CLIENT_ID` and `STILL_GOOGLE_CLIENT_SECRET` in the environment.

Google says a desktop app's client secret isn't confidential, because it ships inside the app. The sign-in itself is
protected by PKCE, and each person's token stays on their own computer (Keychain on Mac, a private file in the settings
folder on Windows and Linux).
