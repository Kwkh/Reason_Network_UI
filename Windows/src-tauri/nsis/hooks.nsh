; 安装/升级/卸载前停止本机的 Reason Network daemon。
; 脚本随安装包放在 backend/ 下，升级时旧版本的脚本也会先被执行。
; 卸载区只能调用 un. 前缀的函数，所以安装和卸载各包一层。
!macro StopReasonDaemonsBody label
  IfFileExists "$INSTDIR\backend\stop-daemons.ps1" 0 ${label}
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\backend\stop-daemons.ps1"'
  Pop $0
  ${label}:
!macroend

Function StopReasonDaemons
  !insertmacro StopReasonDaemonsBody stop_reason_install_done
FunctionEnd

Function un.StopReasonDaemons
  !insertmacro StopReasonDaemonsBody stop_reason_uninstall_done
FunctionEnd

!macro NSIS_HOOK_PREINSTALL
  Call StopReasonDaemons
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  Call un.StopReasonDaemons
!macroend
