; Свобода VPN — установщик (Inno Setup)
[Setup]
AppName=Свобода VPN
AppVersion=1.0
AppPublisher=Svoboda VPN
DefaultDirName={autopf}\SvobodaVPN
DefaultGroupName=Свобода VPN
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
DisableDirPage=auto
UninstallDisplayIcon={app}\svoboda.ico
UninstallDisplayName=Свобода VPN
SetupIconFile=svoboda.ico
OutputDir=dist
OutputBaseFilename=SvobodaVPN-Setup
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "app.ps1";               DestDir: "{app}"; Flags: ignoreversion
Source: "sing-box.exe";          DestDir: "{app}"; Flags: ignoreversion
Source: "wintun.dll";            DestDir: "{app}"; Flags: ignoreversion
Source: "PWDTT.exe";             DestDir: "{app}"; Flags: ignoreversion
Source: "svoboda.ico";           DestDir: "{app}"; Flags: ignoreversion
Source: "register-autostart.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "profiles.empty.json";   DestDir: "{app}"; DestName: "profiles.json"; Flags: onlyifdoesntexist

[Icons]
Name: "{commondesktop}\Свобода VPN"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\app.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\svoboda.ico"
Name: "{group}\Свобода VPN";         Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\app.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\svoboda.ico"
Name: "{group}\Удалить Свобода VPN";  Filename: "{uninstallexe}"

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\register-autostart.ps1"""; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\app.ps1"""; Description: "Запустить «Свобода VPN»"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\register-autostart.ps1"" -Remove"; Flags: runhidden; RunOnceId: "delTask"
Filename: "taskkill.exe"; Parameters: "/im sing-box.exe /f"; Flags: runhidden; RunOnceId: "killSb"

[Code]
function InitializeSetup(): Boolean;
var ResultCode: Integer;
begin
  Exec('taskkill.exe', '/im sing-box.exe /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;
