; Still's entries in the right-click menu for PNG and JPEG files: Open in Still, Copy Text with Still and
; Pin with Still. They go under SystemFileAssociations, so they're added to whatever app opens the file and
; never take over the default. Per user (HKCU), as Still is installed. On Windows 11 they're under
; "Show more options".

!macro StillImageVerb EXT KEY TITLE FLAG
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\${KEY}" "" "${TITLE}"
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\${KEY}" "Icon" "$INSTDIR\${MAINBINARYNAME}.exe"
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\${KEY}\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "${FLAG}=%1"'
!macroend

!macro StillImageVerbs EXT
  !insertmacro StillImageVerb "${EXT}" "StillOpen" "Open in Still" "--open"
  !insertmacro StillImageVerb "${EXT}" "StillText" "Copy Text with Still" "--text"
  !insertmacro StillImageVerb "${EXT}" "StillPin" "Pin with Still" "--pin"
!macroend

!macro StillRemoveImageVerbs EXT
  DeleteRegKey HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\StillOpen"
  DeleteRegKey HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\StillText"
  DeleteRegKey HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\StillPin"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro StillImageVerbs ".png"
  !insertmacro StillImageVerbs ".jpg"
  !insertmacro StillImageVerbs ".jpeg"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro StillRemoveImageVerbs ".png"
  !insertmacro StillRemoveImageVerbs ".jpg"
  !insertmacro StillRemoveImageVerbs ".jpeg"
!macroend
