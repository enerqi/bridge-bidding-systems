; The Windows installer: Inno Setup 6. Built by the release workflow from `just sims dist`'s folder:
;
;   iscc /DAppVersion=0.1.0-alpha.1 /DDistDir=<abs path to target\dist> /O<out dir> packaging\windows\workbench.iss
;
; A PER-USER install: no administrator prompt, into %LOCALAPPDATA%\Programs\Bridge Workbench (what {autopf}
; means with PrivilegesRequired=lowest), a Start-menu entry, an uninstaller in Settings > Apps. Someone who
; wants it for every account can pick that in the first page (PrivilegesRequiredOverridesAllowed=dialog).
;
; What the uninstaller does NOT remove, on purpose: the prefs file (%LOCALAPPDATA%\bridge-workbench\
; workbench.prefs), the deals folder and any notes folder - they are the user's, and a reinstall should find them.

#ifndef AppVersion
  #error Pass the version: /DAppVersion=0.1.0-alpha.1
#endif
#ifndef DistDir
  #error Pass the folder `just sims dist` wrote: /DDistDir=...\target\dist
#endif

[Setup]
; The installer's identity across versions: NEVER change it, or an upgrade installs beside the old copy.
AppId={{ADA1234D-DE08-425F-BC44-C7205CB681F1}
AppName=Bridge Workbench
AppVersion={#AppVersion}
AppVerName=Bridge Workbench {#AppVersion}
AppPublisher=enerqi
AppPublisherURL=https://github.com/enerqi/bridge-bidding-systems
AppSupportURL=https://github.com/enerqi/bridge-bidding-systems/issues
AppUpdatesURL=https://github.com/enerqi/bridge-bidding-systems/releases
DefaultDirName={autopf}\Bridge Workbench
DefaultGroupName=Bridge Workbench
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayName=Bridge Workbench
UninstallDisplayIcon={app}\workbench.exe
; An open window holds workbench.exe and sciter.dll; ask to close it rather than fail to overwrite them.
CloseApplications=yes
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputBaseFilename=bridge-workbench-{#AppVersion}-setup
LicenseFile={#DistDir}\LICENSE.txt

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#DistDir}\workbench.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DistDir}\sciter.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DistDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DistDir}\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Bridge Workbench"; Filename: "{app}\workbench.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Bridge Workbench"; Filename: "{app}\workbench.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\workbench.exe"; Description: "Start Bridge Workbench"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
