
{$i deltics.autoupdate.inc}

  unit Deltics.AutoUpdate;


interface

  uses
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



implementation

  uses
    SysUtils,
    TlHelp32,
    Windows,
    Deltics.IO.FileSearch,
    Deltics.IO.Path,
    Deltics.StringLists,
    Deltics.Strings,
    Deltics.VersionInfo;


  const
    OPT_Apply     = '--autoUpdate:apply';
    OPT_Params    = '--autoUpdate:passThruParams';
    OPT_Relaunch  = '--autoUpdate:relaunch';


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





{ TAutoUpdate }

  procedure TAutoUpdate.CheckForUpdate(const aForceLatest: Boolean);
  var
    currentVer: ISemVer;
    info: IVersionInfo;
    newVersion: String;
  begin
    // If we are applying an update then we don't display the app banner or version etc
    //  as this was already shown when the original process was launched that then
    //  spawned the update process.  Instead we report progress on the update process.

    if IsUpdating then
      ApplyUpdate;

    info := TVersionInfo.Create;
    if NOT info.HasInfo then
    begin
      WriteLn('AutoUpdate not possible: Version info not available');
      EXIT;
    end;

    WriteLn(info.FileDescription + ' ' + info.FileVersion);
    WriteLn('Version ' + info.ProductVersion + ', build ' + info.FileVersionNo);
    WriteLn(info.LegalCopyright);

    // If we were relaunched following the application of an update then there is no need
    //  to check for further updates - we can assume we are up-to-date

    if ParamStr(ParamCount) = OPT_Relaunch then
      EXIT;

    for i := 1 to ParamCount - 1 do
    begin
      if Str.SameText(ParamStr(i), '--autoUpdate:version') then
      begin
        UseVersion(ParamStr(i + 1);
        EXIT;
      end;
    end;

    WriteLn('Checking for update...');

    currentVer := TSemVer.Create(info.FileVersion);

    // If there is no update available then there is no further work to do and we
    //  return to the original caller

    if NOT UpdateAvailable(currentVer, aForceLatest, newVersion) then
      EXIT;

    WriteLn('Update available (Version ' + newVersion + ')');
    WriteLn('Downloading version ' + newVersion + ' ...');
    if NOT Download(newVersion) then
    begin
      WriteLn('DOWNLOAD FAILED! (Update not applied)');
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

    WriteLn('Copying ' + src + ' to ' + dest + ' ...');

    result := CopyFile(PChar(src), PChar(dest), TRUE);
  end;



  function TAutoUpdate.get_IsUpdating: Boolean;
  var
    s: String;
    i: Integer;
    cmd: AnsiString;
  begin
//    if ParamStr(ParamCount - 1) = OPT_Apply then
//    begin
//      s := ParamStr(ParamCount);
//      DeleteFile(PChar(s));
//
//      cmd := Ansi.FromString(ParamStr(0));
//      for i := 1 to ParamCount - 2 do
//        cmd := Ansi.Append(cmd, Ansi.FromString(ParamStr(i)), ' ');
//
//      WinExec(PAnsiChar(cmd), SW_HIDE);
//      Halt(0);
//    end;
//
    result := (ParamStr(1) = OPT_Apply) and (ParamStr(3) = OPT_Params);
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
    params: String;
    old: String;
    cmd: AnsiString;
  begin
    WriteLn('[applying update]');
    WriteLn('Updating software ...');

    target := Path.Append(Path.Branch(ParamStr(0)), ParamStr(2));
    params := ParamStr(4);

    while IsRunning(target) do;

    old := ChangeFileExt(target, '.exe.old');

    WriteLn('  Renaming old version ...');
    RenameFile(target, old);

    WriteLn('  Renaming new version ...');
    RenameFile(ParamStr(0), target);

    WriteLn('  Deleting old version ...');
    DeleteFile(PChar(old));

    cmd := Ansi.FromString(target + ' ' + params + ' ' + OPT_Relaunch);

    WriteLn('Restarting');
    WinExec(PAnsiChar(cmd), SW_HIDE);
    Halt(0);
  end;



  procedure TAutoUpdate.Update(const aVersion: String);
  var
    i: Integer;
    params: String;
    filename: String;
    cmd: AnsiString;
  begin
    // Copy exisitings params (Param(1) thru Params(ParamCount)) to a quoted
    //  string which we can pass on the command line to the autoUpdate phases
    //  so that they propogate to the eventual relaunch of the updated app
    params := '';

    for i := 1 to ParamCount do
      params := params + ParamStr(i) + ' ';

    if Length(params) > 1 then
      SetLength(params, Length(params) - 1);

    params := Str.Enquote(params, '"');

    filename := ChangeFileExt(ExtractFilename(ParamStr(0)), '-' + aVersion + '.exe');

    cmd := Ansi.FromString(Str.Concat([filename,
                                       OPT_Apply,
                                       ExtractFilename(ParamStr(0)),
                                       OPT_Params,
                                       params], ' '));

    WinExec(PAnsiChar(cmd), SW_HIDE);
    Halt(0);
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
  var
    filename: String;
  begin
    WriteLn('Updating to version ' + aVersion + ' ...');

    filename := Path.Leaf(ParamStr(0));
    filename := ChangeFileExt(filename, '-' + aVersion + '.exe');

    if FileExists(Path.Append(Source, filename)) then
      Update(aVersion);

    WriteLn('Requested version ' + aVersion + ' not found.');
    WriteLn;
  end;



end.
