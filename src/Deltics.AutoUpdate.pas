
{$i deltics.autoupdate.inc}

  unit Deltics.AutoUpdate;


interface

  uses
    SysUtils,
    Deltics.InterfacedObjects,
    Deltics.SemVer;


  type
    TAutoUpdatePhase = (auNone, auInitAuto, auInitVersion, auCleanup);


    EAutoUpdateError =  class(Exception);
    EAutoUpdatePhaseComplete =  class(EAbort)
      constructor Create;
    end;


    AutoUpdate = class
      class procedure CheckSource(const aSource: String; const aForceLatest: Boolean);
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
    OPT_Force     = '--autoUpdate:force';
    OPT_NoUpdate  = '--autoUpdate:none';
    OPT_Version   = '--autoUpdate:version';



  type
    TAutoUpdate = class
    private
      fSource: String;
      fTarget: String;
      fTargetBackup: String;
      fTargetUpdate: String;
      function get_Phase: TAutoUpdatePhase;
      procedure Cleanup;
      procedure Download(const aVersion: String);
      procedure UpdateAndTerminate;
      function UpdateAvailable(const aCurrentVersion: ISemVer; var aVersion: String): Boolean;
      procedure UpdateToVersionAndTerminate(const aVersion: String);
    public
      procedure AfterConstruction; override;
      procedure Execute;
      property Phase: TAutoUpdatePhase read get_Phase;
      property Target: String read fTarget;
      property TargetBackup: String read fTargetBackup;
      property TargetUpdate: String read fTargetUpdate;
      property Source: String read fSource write fSource;
    end;





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


  procedure WaitForFile(const aFilename: String);
  var
    iter: Integer;
  begin
    iter := 0;
    while (iter < 10) and (NOT FileExists(aFilename)) do
    begin
      Inc(iter);
      Sleep(100);
    end;

    if NOT FileExists(aFilename) then
      raise EAutoUpdateError.CreateFmt('Required file ''%s'' does not exist', [aFilename]);
  end;


  procedure WaitForNoFile(const aFilename: String);
  var
    iter: Integer;
  begin
    iter := 0;
    while (iter < 10) and FileExists(aFilename) do
    begin
      Inc(iter);
      Sleep(100);
    end;

    if FileExists(aFilename) then
      raise EAutoUpdateError.CreateFmt('File ''%s'' was not deleted', [aFilename]);
  end;


  procedure CopyFileAndWait(const aSource, aDest: String);
  begin
    if CopyFile(PChar(aSource), PChar(aDest), TRUE) then
      WaitForFile(aDest);
  end;


  procedure DeleteFileAndWait(const aFilename: String);
  begin
    if DeleteFile(PChar(aFilename)) then
      WaitForNoFile(aFilename);
  end;


  procedure RenameFileAndWait(const aOldName, aNewName: String);
  begin
    if RenameFile(aOldName, aNewName) then
    begin
      WaitForNoFile(aOldName);
      WaitForFile(aNewName);
    end;
  end;



{ TAutoUpdate }

  procedure TAutoUpdate.Execute;
  var
    i: Integer;
    currentVer: ISemVer;
    info: IVersionInfo;
    newVersion: String;
  begin
    case Phase of
      auNone        : EXIT;

      auCleanup     : begin
                        Cleanup;
                        EXIT;
                      end;

      auInitVersion : begin
                        for i := 1 to ParamCount - 1 do
                          if Str.SameText(ParamStr(i), OPT_Version) then
                          begin
                            UpdateToVersionAndTerminate(ParamStr(i + 1));
                            EXIT;
                          end;
                      end;

    else // auInitAuto
      // Not applying an update and not attempting to apply a specific version,
      //  check for availability of updates in the specified source

      Log.Verbose('Checking for update');

      info := TVersionInfo.Create;
      if NOT info.HasInfo then
      begin
        Log.Warning('AutoUpdate skipped: Version info not available');
        EXIT;
      end;

      currentVer := TSemVer.Create(info.FileVersion);

      // If there is no update available then there is no further work to do and we
      //  return to the original caller

      if NOT UpdateAvailable(currentVer, newVersion) then
        EXIT;

      Download(newVersion);

      Log.Info('Updating to version {version}', [newVersion]);

      UpdateAndTerminate;
    end;
  end;


  procedure TAutoUpdate.AfterConstruction;
  var
    len: Integer;
  begin
    inherited;

    SetLength(fTarget, 2048);
    len := GetModuleFileName(0, PChar(fTarget), Length(fTarget));
    if len <> -1 then
      SetLength(fTarget, len);

    fTargetBackup := fTarget + '.bak';
    fTargetUpdate := fTarget + '.new';
  end;


  procedure TAutoUpdate.Cleanup;
  var
    pid: Cardinal;
  begin
    pid := StrToInt(ParamStr(ParamCount));

    Log.Debug('AutoUpdate: Waiting for process {pid} to terminate', [pid]);

    while IsRunning(pid) do Sleep(10);

    Log.Debug('AutoUpdate: Deleting {bak}', [Path.Leaf(TargetBackup)]);

    DeleteFileAndWait(TargetBackup);
  end;


  procedure TAutoUpdate.Download(const aVersion: String);
  var
    filename: String;
    src: String;
  begin
    filename := ChangeFileExt(Path.Leaf(Target), '-' + aVersion + '.exe');

    src := Path.Append(Source, filename);

    if NOT FileExists(src) then
    begin
      Log.Error('AutoUpdate: Update file ''{update}'' not found', [src]);
      EXIT;
    end;

    if FileExists(TargetUpdate) then
    begin
      Log.Debug('AutoUpdate: Deleting existing update file {update}', [Path.Leaf(TargetUpdate)]);
      DeleteFileAndWait(TargetUpdate);
    end;

    Log.Debug('AutoUpdate: Copying update file {src} to {dest}', [filename, Path.Leaf(TargetUpdate)]);

    CopyFileAndWait(src, TargetUpdate);
  end;


  function TAutoUpdate.get_Phase: TAutoUpdatePhase;
  var
    i: Integer;
  begin
    if Str.SameText(ParamStr(ParamCount), OPT_NoUpdate) then
    begin
      result := auNone;
      EXIT;
    end;

    if Str.SameText(ParamStr(ParamCount - 1), Opt_Cleanup) then
    begin
      result := auCleanup;
      EXIT;
    end;

    for i := 1 to ParamCount - 1 do
    begin
      if Str.SameText(ParamStr(i), OPT_Version) then
      begin
        result := auInitVersion;
        EXIT;
      end;
    end;

    result := auInitAuto;
  end;


  procedure TAutoUpdate.UpdateAndTerminate;
  var
    i: Integer;
    params: String;
    orgFilename: String;
    cmd: String;
  begin
    if NOT FileExists(TargetUpdate) then
    begin
      Log.Error('AutoUpdate: Update file {update} not found', [TargetUpdate]);
      EXIT;
    end;

    if FileExists(TargetBackup) then
    begin
      Log.Debug('AutoUpdate: Deleting existing {backup}', [Path.Leaf(TargetBackup)]);
      DeleteFileAndWait(TargetBackup);
    end;

    Log.Debug('AutoUpdate: Renaming {target} as {backup}', [Path.Leaf(Target), Path.Leaf(TargetBackup)]);
    RenameFileAndWait(Target, TargetBackup);

    Log.Debug('AutoUpdate: Renaming {update} as {target}', [Path.Leaf(TargetUpdate), Path.Leaf(Target)]);
    RenameFileAndWait(TargetUpdate, Target);

    // Copy existing params (Param(1) thru Params(ParamCount)) to a quoted
    //  string which we can pass on the command line to the autoUpdate phases
    //  so that they propogate to the eventual relaunch of the updated app
    //
    // NB. Strips out any --autoupdate:version options (and associated value).

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

    cmd := Str.Concat([orgFilename, params, OPT_Cleanup, IntToStr(GetCurrentProcessId)], ' ');

    Log.Debug('AutoUpdate: Relaunching updated application with command line {cmd}', [cmd]);
    Exec(cmd, FALSE);

    raise EAutoUpdatePhaseComplete.Create;
  end;



  function TAutoUpdate.UpdateAvailable(const aCurrentVersion: ISemVer;
                                       var aVersion: String): Boolean;
  var
    i: Integer;
    filenameStem: String;
    filename: String;
    available: IStringList;
    ver: ISemVer;
    latest: ISemVer;
    forceUpdate: Boolean;
  begin
    forceUpdate := FALSE;

    for i := 1 to ParamCount do
    begin
      forceUpdate := Str.SameText(ParamStr(i), OPT_Force);
      if forceUpdate then
        BREAK;
    end;

    result    := FALSE;
    aVersion  := '';

    filenameStem := ChangeFileExt(ExtractFilename(ParamStr(0)), '-');

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

    result := Assigned(latest) and (forceUpdate or latest.IsNewerThan(aCurrentVersion));

    if result then
      aVersion := latest.AsString
    else if Assigned(latest) then
      Log.Debug('AutoUpdate: No update required (already up-to-date)')
    else
      Log.Debug('AutoUpdate: No updates found');
  end;



  procedure TAutoUpdate.UpdateToVersionAndTerminate(const aVersion: String);
  begin
    Log.Debug('AutoUpdate: Checking for availability of {version}', [aVersion]);

    Download(aVersion);

    Log.Info('Updating to version {version}', [aVersion]);

    UpdateAndTerminate;

    raise EAutoUpdatePhaseComplete.Create;
  end;



{ EAutoUpdatePhaseComplete }

  constructor EAutoUpdatePhaseComplete.Create;
  begin
    inherited Create('AutoUpdate phase complete');

    Log.Debug('AutoUpdate: Phase complete');
  end;





{ AutoUpdate }

  class procedure AutoUpdate.CheckSource(const aSource: String;
                                         const aForceLatest: Boolean);
  var
    updater: TAutoUpdate;
  begin
    updater := TAutoUpdate.Create;
    try
      updater.Source := aSource;
      updater.Execute;

    finally
      updater.Free;
    end;
  end;




end.
