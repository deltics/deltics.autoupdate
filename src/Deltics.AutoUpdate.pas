
{$i deltics.autoupdate.inc}

  unit Deltics.AutoUpdate;


interface

  uses
    SysUtils,
    Deltics.InterfacedObjects,
    Deltics.SemVer;


  type
    IAutoUpdate = interface
    ['{0D220A22-795A-4798-B345-A4B55F686252}']
      function get_Source: String;
      procedure set_Source(const aValue: String);
      procedure CheckForUpdate(const aForceLatest: Boolean);
      property Source: String read get_Source write set_Source;
    end;


    TAutoUpdate = class(TComInterfacedObject, IAutoUpdate)
    protected // IAutoUpdate
      function get_Source: String;
      procedure set_Source(const aValue: String);
    public
      procedure CheckForUpdate(const aForceLatest: Boolean);

    private
      fSource: String;
      function get_IsUpdating: Boolean;
      procedure ApplyUpdate;
      function Download(const aVersion: String): Boolean;
      procedure Update(const aVersion: String);
      function UpdateAvailable(const aCurrentVersion: ISemVer; const aForceLatest: Boolean; var aVersion: String): Boolean;
      procedure UseVersion(const aVersion: String);
      property IsUpdating: Boolean read get_IsUpdating;
    public
      property Source: String read fSource write fSource;
    end;


  type
    EAutoUpdatePhaseComplete =  class(EAbort)
      constructor Create;
    end;



implementation

  uses
    TlHelp32,
    Windows,
    Deltics.IO.FileSearch,
    Deltics.IO.Path,
    Deltics.Radiata,
    Deltics.StringLists,
    Deltics.Strings,
    Deltics.VersionInfo;


  const
    OPT_Apply     = '--autoUpdate:apply';
    OPT_Params    = '--autoUpdate:passThruParams';
    OPT_Relaunch  = '--autoUpdate:relaunch';
    OPT_Version   = '--autoUpdate:version';


  function IsRunning(aExe: String): Boolean;
  var
    exeName: String;
    processName: String;
    more: BOOL;
    snapshot: THandle;
    proc: TProcessEntry32;
  begin
    result := FALSE;

    snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    try
      exeName := UpperCase(aExe);

      proc.dwSize := SizeOf(proc);
      more := Process32First(snapshot, proc);
      while Integer(more) <> 0 do
      begin
        processName := Uppercase(proc.szExeFile);

        result := (exeName = processName)
               or (exeName = ExtractFileName(processName));
        if result then
          BREAK;

        more := Process32Next(snapshot, proc);
      end;

    finally
      CloseHandle(snapshot);
    end;
  end;


  procedure Exec(const aCommandLine: String);
  var
    si: TStartupInfo;
    pi: TProcessInformation;
  begin
    ZeroMemory(@si, sizeof(si));
    si.cb := sizeof(si);
    ZeroMemory(@pi, sizeof(pi));

    // Start the child process.
    if CreateProcess( NIL,   // No module name (use command line)
                      PChar(aCommandLine),        // Command line
                      NIL,           // Process handle not inheritable
                      NIL,           // Thread handle not inheritable
                      FALSE,          // Set handle inheritance to FALSE
                      0,              // No creation flags
                      NIL,           // Use parent's environment block
                      NIL,           // Use parent's starting directory
                      si,            // Pointer to STARTUPINFO structure
                      pi )           // Pointer to PROCESS_INFORMATION structure

    then
    begin
      // Close process and thread handles.
      CloseHandle(pi.hProcess);
      CloseHandle(pi.hThread);
    end;
  end;





{ TAutoUpdate }

  procedure TAutoUpdate.CheckForUpdate(const aForceLatest: Boolean);
  var
    i: Integer;
    currentVer: ISemVer;
    info: IVersionInfo;
    newVersion: String;
  begin
    // If we are applying an update then we don't display the app banner or version etc
    //  as this was already shown when the original process was launched that then
    //  spawned the update process.  Instead we report progress on the update process.

    if IsUpdating then
    begin
      ApplyUpdate;
      EXIT;
    end;

    info := TVersionInfo.Create;
    if NOT info.HasInfo then
    begin
      Log.Warning('AutoUpdate skipped: Version info not available');
      EXIT;
    end;

    // Check for specific version to be applied (if available)

    for i := 1 to ParamCount - 1 do
      if Str.SameText(ParamStr(i), OPT_Version) then
      begin
        UseVersion(ParamStr(i + 1));
        EXIT;
      end;

    // Not applying an update and not attempting to apply a specific version,
    //  check for availability of updates in the specified source

    Log.Verbose('Checking for update');

    currentVer := TSemVer.Create(info.FileVersion);

    // If there is no update available then there is no further work to do and we
    //  return to the original caller

    if NOT UpdateAvailable(currentVer, aForceLatest, newVersion) then
      EXIT;

    Log.Debug('AutoUpdate: Found update to version {version}', [newVersion]);
    Log.Debug('AutoUpdate: Downloading version {version]', [newVersion]);

    if NOT Download(newVersion) then
    begin
      Log.Error('AutoUpdate: Download of updated version {version} failed', [newVersion]);
      EXIT;
    end;

    Update(newVersion);
  end;


  function TAutoUpdate.Download(const aVersion: String): Boolean;
  var
    filename: String;
    src: String;
    dest: String;
  begin
    filename := ChangeFileExt(Path.Leaf(ParamStr(0)), '-' + aVersion + '.exe');

    src   := Path.Append(Source, filename);
    dest  := Path.Append(Path.Branch(ParamStr(0)), filename);

    Log.Debug('AutoUpdate: Copying {src} to {dest}', [src, dest]);

    result := CopyFile(PChar(src), PChar(dest), TRUE);
  end;


  function TAutoUpdate.get_IsUpdating: Boolean;
  begin
    result := (ParamStr(ParamCount - 1) = OPT_Apply);
  end;


  function TAutoUpdate.get_Source: String;
  begin
    result := fSource;
  end;


  procedure TAutoUpdate.set_Source(const aValue: String);
  begin
    fSource := aValue;
  end;







  procedure TAutoUpdate.ApplyUpdate;
  var
    target: String;
    old: String;
  begin
    target := Path.Append(Path.Branch(ParamStr(0)), ParamStr(ParamCount));

    Log.Debug('AutoUpdate: Waiting for {originaProcess} to terminate', [target]);

    while IsRunning(target) do;

    old := ChangeFileExt(target, '.exe.old');

    Log.Debug('AutoUpdate: Renaming {target} as {old}', [target, old]);
    RenameFile(target, old);

    Log.Debug('AutoUpdate: Renaming {updated} as {target}', [ParamStr(0), target]);
    RenameFile(ParamStr(0), target);

    Log.Debug('AutoUpdate: Deleting {old}', [old]);
    DeleteFile(PChar(old));
  end;



  procedure TAutoUpdate.Update(const aVersion: String);
  var
    i: Integer;
    params: String;
    orgFilename: String;
    updatedFilename: String;
    cmd: String;
  begin
    // Copy exisitings params (Param(1) thru Params(ParamCount)) to a quoted
    //  string which we can pass on the command line to the autoUpdate phases
    //  so that they propogate to the eventual relaunch of the updated app
    params := '';

    for i := 1 to ParamCount do
    begin
      if Str.SameText(ParamStr(i), OPT_Version)
       or Str.SameText(ParamStr(i - 1), OPT_Version) then
        CONTINUE;

      params := params + ParamStr(i) + ' ';
    end;

    if Length(params) > 1 then
      SetLength(params, Length(params) - 1);

    orgFilename     := ExtractFilename(ParamStr(0));
    updatedFilename := ChangeFileExt(orgFilename, '-' + aVersion + '.exe');

    cmd := Str.Concat([updatedFilename,
                       params,
                       OPT_Apply,
                       orgFilename], ' ');

    Exec(cmd);

    raise EAutoUpdatePhaseComplete.Create;
  end;



  function TAutoUpdate.UpdateAvailable(const aCurrentVersion: ISemVer;
                                       const aForceLatest: Boolean;
                                       var aVersion: String): Boolean;
  var
    i: Integer;
    filenameStem: String;
    filename: String;
    available: IStringList;
    ver: ISemVer;
    latest: ISemVer;
  begin
    result    := FALSE;
    aVersion  := '';

    filenameStem  := ChangeFileExt(ExtractFilename(ParamStr(0)), '-');

    if NOT FileSearch.Filename(filenameStem + '*.exe')
            .Folder(Source)
            .Yielding.Files(available)
            .Execute then
      EXIT;

    for i := 0 to Pred(available.Count) do
    begin
      filename := ChangeFileExt(available[i], '');
      Delete(filename, 1, Length(filenameStem));

      ver := TSemVer.Create(filename);
      if NOT Assigned(latest) or ver.IsNewerThan(latest) then
        latest := ver;
    end;

    result := Assigned(latest) and (aForceLatest or latest.IsNewerThan(aCurrentVersion));

    if result then
      aVersion := latest.AsString;
  end;





  procedure TAutoUpdate.UseVersion(const aVersion: String);
  begin
    Log.Debug('AutoUpdate: Checking for availability of {version}', [aVersion]);

    if Download(aVersion) then
      Update(aVersion);

    Log.Error('AutoUpdate: Version {version} cannot be found', [aVersion]);

    raise EAutoUpdatePhaseComplete.Create;
  end;



{ EAutoUpdatePhaseComplete }

  constructor EAutoUpdatePhaseComplete.Create;
  begin
    inherited Create('AutoUpdate phase complete');
  end;



end.
