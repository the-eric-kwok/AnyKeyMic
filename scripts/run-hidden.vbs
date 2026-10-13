Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
root = files.GetParentFolderName(files.GetParentFolderName(WScript.ScriptFullName))
logDir = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\AnyKeyMic"
If Not files.FolderExists(logDir) Then files.CreateFolder(logDir)
shell.Run "cmd.exe /d /s /c """"" & root & "\dist\anykey-mic.exe"" run >> """ & logDir & "\run.log"" 2>&1""", 0, False
