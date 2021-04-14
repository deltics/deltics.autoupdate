
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
      procedure Cleanup;
      function Download(const aVersion: String): Boolean;
      procedure Update(const aVersion: String);
      function UpdateAvailable(const aCurrentVersion: ISemVer; const aForceLatest: Boolean; var aVersion: String): Boolean;
      procedure UseVersion(const aVersion: String);
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
    OPT_Cleanup   = '--autoUpdate:cleanup';
    OPT_Version   = '--autoUpdate:version';
    OPT_NoUpdate  = '--autoUpdate:none';


  function IsRunning(aPID: Cardinal): Boolean;
  var
    more: BOOL;
    snapshot: THandle;
    proc: TProcessEntry32;
  begin
    result := FALSE;

    snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    try
      proc.dwSize := SizeOf(proc);
      more := Process32First(snapshot, proc);
      while Integer(more) <> 0 do
      begin
        result := aPID = proc.th32ProcessID;
        if result then
          BREAK;

        more := Process32Next(snapshot, proc);
      end;

    finally
      CloseHandle(snapshot);
    end;
  end;


  procedure Exec(const aCommandLine: String; const aAndWait: Boolean);
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
                      TRUE,          // Set handle inheritance to FALSE
                      0,             // No creation flags
                      NIL,           // Use parent's environment block
                      NIL,           // Use parent's starting directory
                      si,            // Pointer to STARTUPINFO structure
                      pi )           // Pointer to PROCESS_INFORMATION structure

    then
    begin
      if aAndWait then
        WaitForSingleObject(pi.hProcess, INFINITE);

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
    if Str.SameText(ParamStr(ParamCount), OPT_NoUpdate) then
      EXIT;

    if Str.SameText(ParamStr(ParamCount - 2), Opt_Cleanup) then
    begin
      Cleanup;
      raise EAutoUpdatePhaseComplete.Create;
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
    Log.Debug('AutoUpdate: Downloading version {version}', [newVersion]);

    if NOT Download(newVersion) then
    begin
      Log.Error('AutoUpdate: Download of updated version {version} failed', [newVersion]);
      EXIT;
    end;

    Update(newVersion);
  end;


  procedure TAutoUpdate.Cleanup;
  var
    pid: Cardinal;
    bak: String;
  begin
    pid := StrToInt(ParamStr(ParamCount));

    Log.Debug('AutoUpdate: Waiting for process {pid} to terminate', [pid]);

    while IsRunning(pid) do;

    bak := Str.Unquote(ParamStr(ParamCount - 1));

    Log.Debug('AutoUpdate: Deleting {bak}', [bak]);
    DeleteFile(PChar(bak));
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


  function TAutoUpdate.get_Source: String;
  begin
    result := fSource;
  end;


  procedure TAutoUpdate.set_Source(const aValue: String);
  begin
    fSource := aValue;
  end;







  procedure TAutoUpdate.Update(const aVersion: String);
  var
    i: Integer;
    params: String;
    orgFilename: String;
    bak: String;
    updatedFilename: String;
    cmd: String;
  begin
    Log.Info('Updating to version {version}', [aVersion]);

    // Copy existing params (Param(1) thru Params(ParamCount)) to a quoted
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
    bak             := orgFilename + '.bak';
    updatedFilename := ChangeFileExt(orgFilename, '-' + aVersion + '.exe');

    Log.Debug('AutoUpdate: Renaming {target} as {old}', [orgFilename, bak]);
    RenameFile(orgFilename, bak);
    try
      Log.Debug('AutoUpdate: Renaming {updated} as {target}', [updatedFilename, orgFilename]);
      RenameFile(updatedFilename, orgFilename);

      cmd := Str.Concat([orgFilename,
                         params], ' ');

      Exec(Str.Concat([cmd, OPT_NoUpdate], ' '), TRUE);

    except
      if FileExists(orgFilename) then
      begin
        Log.Debug('AutoUpdate: Deleting {target}', [orgFilename]);
        DeleteFile(PChar(orgFilename));
      end;

      Log.Debug('AutoUpdate: Restoring {bak}', [bak]);
      RenameFile(bak, orgFilename);

      raise;
    end;

    Exec(Str.Concat([cmd, OPT_Cleanup,
                     Str.Enquote(bak),
                     IntToStr(GetCurrentProcessId)], ' '), FALSE);

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
