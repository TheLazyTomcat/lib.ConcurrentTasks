unit ConcurrentTasks;

{$IF not(Defined(WINDOWS) or Defined(MSWINDOWS))}
  {$MESSAGE FATAL 'Unsupported operating system.'}
{$IFEND}

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$TYPEINFO ON}

interface

uses
  Classes,
  AuxTypes, Messanger, WinSyncObjs;

const
  CNTS_MSGR_ENDPOINT_MANAGER = 0;

  CNTS_MSG_USER      = 0;
  CNTS_MSG_TERMINATE = 1;
  CNTS_MSG_PROGRESS  = 2;
  CNTS_MSG_COMPLETED = 3;

type
  TCNTSMessageEndpoint = TMsgrEndpointID;
  TCNTSMessageParam    = TMsgrParam;
  TCNTSMessageResult   = TMsgrParam;

  TCNTSMessage = record
    Sender: TCNTSMessageEndpoint;
    Param1: TCNTSMessageParam;
    Param2: TCNTSMessageParam;
    Result: TCNTSMessageResult;
  end;

  TCNTSMessageEvent = procedure(Sender: TObject; var Msg: TCNTSMessage) of object;

  TCNTSTask = class(TObject)
  private
    fCommEndpoint:  TMessangerEndpoint;
    fPauseObject:   TEvent;
    fTerminated:    Integer;
    Function GetTerminated: Boolean;
    procedure SetTerminated(Value: Boolean);
  protected
    procedure MessageHandler(Sender: TObject; Msg: TMsgrMessage; var Flags: TMsgrDispatchFlags); virtual;
  public
    procedure SetInternals(CommEndpoint: TMessangerEndpoint; PauseObject: TEvent);  // static
    procedure Execute;                                                              // static
    Function PostMessage(Param1,Param2: TCNTSMessageParam): Boolean; virtual;
    Function SendMessage(Param1,Param2: TCNTSMessageParam): TCNTSMessageResult; virtual;
    procedure SignalProgress(Progress: Single); virtual;
    procedure Cycle; virtual;
    procedure ProcessMessage(var Msg: TCNTSMessage); virtual;
    Function Main: Boolean; virtual; abstract;
  published
    property Terminated: Boolean read GetTerminated write SetTerminated;
  end;

  TCNTSThread = class(TThread)
  private
    fTaskObject:    TCNTSTask;
    fCommEndpoint:  TMessangerEndpoint;
  protected
    procedure Execute; override;
  public
    constructor Create(TaskObject: TCNTSTask; CommEndpoint: TMessangerEndpoint; PauseObject: TEvent);
  end;

  TCNTSTaskState = (tsReady,tsRunning,tsWaiting,tsPaused,tsCompleted,tsAborted);

  TCNTSTaskItem = record
    State:      TCNTSTaskState;
    TaskObject: TCNTSTask;
    Progress:   Single;
  end;
  PCNTSTaskItem = ^TCNTSTaskItem;

  TCNTSTaskItemFull = record
    PublicPart:     TCNTSTaskItem;
    CommEndpoint:   TMessangerEndpoint;
    PauseObject:    TEvent;
    AssignedThread: TCNTSThread;
  end;
  PCNTSTaskItemFull = ^TCNTSTaskItemFull;

  TCNTSTasks = array of TCNTSTaskItemFull;

  TCNTSTaskEvent = procedure(Sender: TObject; TaskIndex: Integer) of object;

  TCNTSManager = class(TObject)
  private
    fOwnsTaskObjects:     Boolean;
    fTasks:               TCNTSTasks;
    fMaxConcurrentTasks:  Integer;
    fMessanger:           TMessanger;
    fCommEndpoint:        TMessangerEndpoint;
    fOnMessage:           TCNTSMessageEvent;
    fOnTaskState:         TCNTSTaskEvent;
    fOnTaskProgress:      TCNTSTaskEvent;
    fOnTaskCompleted:     TCNTSTaskEvent;
    fOnTaskRemove:        TCNTSTaskEvent;
    Function GetTaskCount: Integer;
    Function GetTask(Index: Integer): TCNTSTaskItem;
    procedure SetMaxConcurrentTasks(Value: Integer);
  protected
    procedure MessageHandler(Sender: TObject; Msg: TMsgrMessage; var Flags: TMsgrDispatchFlags); virtual;
    procedure ManageRunningTasks; virtual;
  public
    class Function GetProcessorCount: Integer; virtual;
    constructor Create(OwnsTaskObjects: Boolean = True);
    destructor Destroy; override;
    procedure Update(WaitTimeOut: LongWord = 0); virtual;
    Function IndexOfTask(TaskObject: TCNTSTask): Integer; overload; virtual;
    Function IndexOfTask(CommEndpointID: TCNTSMessageEndpoint): Integer; overload; virtual;
    Function AddTask(TaskObject: TCNTSTask): Integer; virtual;
    Function RemoveTask(TaskObject: TCNTSTask): Integer; virtual;
    procedure DeleteTask(TaskIndex: Integer); virtual;
    Function ExtractTask(TaskObject: TCNTSTask): TCNTSTask; virtual;
    procedure ClearTasks; virtual;
    procedure ClearCompletedTasks; virtual;
    procedure StartTask(TaskIndex: Integer); virtual;
    procedure PauseTask(TaskIndex: Integer); virtual;
    procedure ResumeTask(TaskIndex: Integer); virtual;
    procedure StopTask(TaskIndex: Integer); virtual;
    procedure WaitForRunningTasksToComplete; virtual;
    Function PostMessage(TaskIndex: Integer; Param1,Param2: TCNTSMessageParam): Boolean; virtual;
    Function SendMessage(TaskIndex: Integer; Param1,Param2: TCNTSMessageParam): TCNTSMessageResult; virtual;
    Function GetRunningTaskCount: Integer; virtual;
    Function GetActiveTaskCount(CountPaused: Boolean = False): Integer; virtual;
    property Tasks[Index: Integer]: TCNTSTaskItem read GetTask; default;
  published
    property TaskCount: Integer read GetTaskCount;
    property MaxConcurrentTasks: Integer read fMaxConcurrentTasks write SetMaxConcurrentTasks;
    property OnMessage: TCNTSMessageEvent read fOnMessage write fOnMessage;
    property OnTaskState: TCNTSTaskEvent read fOnTaskState write fOnTaskState;
    property OnTaskProgress: TCNTSTaskEvent read fOnTaskProgress write fOnTaskProgress;
    property OnTaskCompleted: TCNTSTaskEvent read fOnTaskCompleted write fOnTaskCompleted; 
    property OnTaskRemove: TCNTSTaskEvent read fOnTaskRemove write fOnTaskRemove;
  end;

implementation

uses
  Windows, SysUtils;

procedure GetNativeSystemInfo(lpSystemInfo: PSystemInfo); stdcall; external kernel32;

//==============================================================================
//------------------------------------------------------------------------------
//==============================================================================

Function TCNTSTask.GetTerminated: Boolean;
begin
Result := InterlockedExchangeAdd(fTerminated,0) <> 0;
end;

//------------------------------------------------------------------------------

procedure TCNTSTask.SetTerminated(Value: Boolean);
begin
If Value then InterlockedExchange(fTerminated,-1)
  else InterlockedExchange(fTerminated,0);
end;

//==============================================================================

procedure TCNTSTask.MessageHandler(Sender: TObject; Msg: TMsgrMessage; var Flags: TMsgrDispatchFlags);
var
  InternalMessage:  TCNTSMessage;
begin
case Msg.Parameter1 of
  CNTS_MSG_USER:
    begin
      InternalMessage.Sender := Msg.Sender;
      InternalMessage.Param1 := Msg.Parameter2;
      InternalMessage.Param2 := Msg.Parameter3;
      InternalMessage.Result := 0;
      ProcessMessage(InternalMessage);
      If mdfSynchronousMessage in Flags then
        TCNTSMessageResult({%H-}Pointer(Msg.Parameter4)^) := InternalMessage.Result;
    end;
  CNTS_MSG_TERMINATE:
    Terminated := True;
end;
end;

//==============================================================================

procedure TCNTSTask.SetInternals(CommEndpoint: TMessangerEndpoint; PauseObject: TEvent);
begin
fCommEndpoint := CommEndpoint;
fCommEndpoint.OnMessageTraversing := MessageHandler;
fPauseObject := PauseObject;
end;

//------------------------------------------------------------------------------

procedure TCNTSTask.Execute;
begin
Cycle;
fCommEndpoint.SendMessage(CNTS_MSGR_ENDPOINT_MANAGER,CNTS_MSG_COMPLETED,Ord(Main),0,0)
end;

//------------------------------------------------------------------------------

Function TCNTSTask.PostMessage(Param1,Param2: TCNTSMessageParam): Boolean;
begin
Result := fCommEndpoint.SendMessage(CNTS_MSGR_ENDPOINT_MANAGER,CNTS_MSG_USER,Param1,Param2,0);
end;

//------------------------------------------------------------------------------

Function TCNTSTask.SendMessage(Param1,Param2: TCNTSMessageParam): TCNTSMessageResult;
begin
fCommEndpoint.SendMessageAndWait(CNTS_MSGR_ENDPOINT_MANAGER,CNTS_MSG_USER,Param1,Param2,{%H-}TMsgrParam(Addr(Result)));
end;

//------------------------------------------------------------------------------

procedure TCNTSTask.SignalProgress(Progress: Single);
var
  Value:  TCNTSMessageParam;
begin
Value := TCNTSMessageParam(UInt32(Addr(Progress)^));
fCommEndpoint.SendMessage(CNTS_MSGR_ENDPOINT_MANAGER,CNTS_MSG_PROGRESS,Value,0,0);
end;

//------------------------------------------------------------------------------

procedure TCNTSTask.Cycle;
begin
fCommEndpoint.Cycle(0); // do not wait
fPauseObject.WaitFor;
end;

//------------------------------------------------------------------------------

procedure TCNTSTask.ProcessMessage(var Msg: TCNTSMessage);
begin
Msg.Result := 0;
end;

//==============================================================================
//------------------------------------------------------------------------------
//==============================================================================

procedure TCNTSThread.Execute;
begin
fTaskObject.Execute;
end;

//==============================================================================

constructor TCNTSThread.Create(TaskObject: TCNTSTask; CommEndpoint: TMessangerEndpoint; PauseObject: TEvent);
begin
inherited Create(False);
FreeOnTerminate := False;
fTaskObject := TaskObject;
fCommEndpoint := CommEndpoint;
fTaskObject.SetInternals(CommEndpoint,PauseObject);
end;

//==============================================================================
//------------------------------------------------------------------------------
//==============================================================================

Function TCNTSManager.GetTaskCount: Integer;
begin
Result := Length(fTasks);
end;

//------------------------------------------------------------------------------

Function TCNTSManager.GetTask(Index: Integer): TCNTSTaskItem;
begin
If (Index >= Low(fTasks)) and (Index <= High(fTasks)) then
  Result := fTasks[Index].PublicPart
else
  raise Exception.CreateFmt('TCNTSManager.GetTask: Index(%d) out of bounds.',[Index]);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.SetMaxConcurrentTasks(Value: Integer);
begin
If Value >= 1 then
  begin
    fMaxConcurrentTasks := Value;
    ManageRunningTasks;
  end
else raise Exception.CreateFmt('TCNTSManager.SetMaxConcurrentTasks: Cannot assign value smaller than 1 (%d).',[Value]);
end;

//==============================================================================

procedure TCNTSManager.MessageHandler(Sender: TObject; Msg: TMsgrMessage; var Flags: TMsgrDispatchFlags);
var
  InternalMessage:  TCNTSMessage;
  Index:            Integer;
begin
case Msg.Parameter1 of
  CNTS_MSG_USER:
    begin
      InternalMessage.Sender := Msg.Sender;
      InternalMessage.Param1 := Msg.Parameter2;
      InternalMessage.Param2 := Msg.Parameter3;
      InternalMessage.Result := 0;
      If Assigned(fOnMessage) then
        fOnMessage(Self,InternalMessage);
      If mdfSynchronousMessage in Flags then
        TCNTSMessageResult({%H-}Pointer(Msg.Parameter4)^) := InternalMessage.Result;
    end;
  CNTS_MSG_PROGRESS:
    begin
      Index := IndexOfTask(Msg.Sender);
      If Index >= 0 then
        If Single(Addr(Msg.Parameter2)^) > fTasks[Index].PublicPart.Progress then
          begin
            fTasks[Index].PublicPart.Progress := Single(Addr(Msg.Parameter2)^);
            If Assigned(fOnTaskProgress) then
              fOnTaskProgress(Sender,Index);
          end;
    end;
  CNTS_MSG_COMPLETED:
    begin
      Index := IndexOfTask(Msg.Sender);
      If Index >= 0 then
        begin
          If Msg.Parameter2 <> 0 then
            fTasks[Index].PublicPart.State := tsCompleted
          else
            fTasks[Index].PublicPart.State := tsAborted;
          If Assigned(fOnTaskState) then
            fOnTaskState(Self,Index);
          If Assigned(fOnTaskCompleted) then
            fOnTaskCompleted(Self,Index);
        end;
      ManageRunningTasks;
    end;
end;
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.ManageRunningTasks;
var
  RunCount: Integer;
  i:        Integer;
begin
RunCount := fMaxConcurrentTasks - GetRunningTaskCount;
For i := Low(fTasks) to High(fTasks) do
  If RunCount > 0 then
    begin
      If fTasks[i].PublicPart.State = tsReady then
        begin
          StartTask(i);
          Dec(RunCount);
        end;
    end
  else Break{For i};
end;

//==============================================================================

class Function TCNTSManager.GetProcessorCount: Integer;
var
  SysInfo:  TSystemInfo;
begin
GetNativeSystemInfo(@SysInfo);
Result := Integer(SysInfo.dwNumberOfProcessors);
If Result < 1 then
  Result := 1;
end;

//------------------------------------------------------------------------------

constructor TCNTSManager.Create(OwnsTaskObjects: Boolean = True);
begin
inherited Create;
fOwnsTaskObjects := OwnsTaskObjects;
SetLength(fTasks,0);
fMaxConcurrentTasks := GetProcessorCount;
fMessanger := TMessanger.Create;
fCommEndpoint := fMessanger.CreateEndpoint(0);
fCommEndpoint.OnMessageTraversing := MessageHandler;
end;

//------------------------------------------------------------------------------

destructor TCNTSManager.Destroy;
begin
ClearTasks;
fCommEndpoint.Free;
fMessanger.Free;
SetLength(fTasks,0);
inherited;
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.Update(WaitTimeOut: LongWord = 0);
begin
fCommEndpoint.Cycle(WaitTimeOut);
ManageRunningTasks;
end;

//------------------------------------------------------------------------------

Function TCNTSManager.IndexOfTask(TaskObject: TCNTSTask): Integer;
var
  i:  Integer;
begin
Result := -1;
For i := Low(fTasks) to High(fTasks) do
  If fTasks[i].PublicPart.TaskObject = TaskObject then
    begin
      Result := i;
      Break;
    end;
end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

Function TCNTSManager.IndexOfTask(CommEndpointID: TCNTSMessageEndpoint): Integer;
var
  i:  Integer;
begin
Result := -1;
For i := Low(fTasks) to High(fTasks) do
  If fTasks[i].CommEndpoint.EndpointID = CommEndpointID then
    begin
      Result := i;
      Break;
    end;
end;

//------------------------------------------------------------------------------

Function TCNTSManager.AddTask(TaskObject: TCNTSTask): Integer;
var
  NewTaskItem:  TCNTSTaskItemFull;
begin
NewTaskItem.PublicPart.State := tsReady;
NewTaskItem.PublicPart.TaskObject := TaskObject;
NewTaskItem.PublicPart.Progress := 0.0;
NewTaskItem.CommEndpoint := fMessanger.CreateEndpoint;
NewTaskItem.PauseObject := TEvent.Create(nil,True,True,'');
// thread is created only when the task is started
NewTaskItem.AssignedThread := nil;
SetLength(fTasks,Length(fTasks) + 1);
Result := High(fTasks);
fTasks[Result] := NewTaskItem;
If Assigned(fOnTaskState) then
  fOnTaskState(Self,Result);
ManageRunningTasks;
end;

//------------------------------------------------------------------------------

Function TCNTSManager.RemoveTask(TaskObject: TCNTSTask): Integer;
begin
Result := IndexOfTask(TaskObject);
If Result >= 0 then DeleteTask(Result);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.DeleteTask(TaskIndex: Integer);
var
  i:  Integer;
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  begin
    If not(fTasks[TaskIndex].PublicPart.State in [tsRunning,tsPaused]) then
      begin
        If Assigned(fTasks[TaskIndex].AssignedThread) then
          begin
            fTasks[TaskIndex].AssignedThread.WaitFor;
            FreeAndNil(fTasks[TaskIndex].AssignedThread);
          end;
        If Assigned(fTasks[TaskIndex].CommEndpoint) then
          begin
            fTasks[TaskIndex].CommEndpoint.OnMessageTraversing := nil;
            FreeAndNil(fTasks[TaskIndex].CommEndpoint);
          end;
        fTasks[TaskIndex].PauseObject.Free;
        If fOwnsTaskObjects then
          fTasks[TaskIndex].PublicPart.TaskObject.Free
        else
          If Assigned(fOnTaskRemove) then fOnTaskRemove(Self,TaskIndex);
        For i := TaskIndex to Pred(High(fTasks)) do
          fTasks[i] := fTasks[i + 1];
        SetLength(fTasks,Length(fTasks) - 1);
      end
    else raise Exception.CreateFmt('TCNTSManager.DeleteTask: Cannot delete running task (#%d).',[TaskIndex]);
  end
else raise Exception.CreateFmt('TCNTSManager.DeleteTask: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

Function TCNTSManager.ExtractTask(TaskObject: TCNTSTask): TCNTSTask;
var
  Index:  Integer;
  i:      Integer;
begin
Index := IndexOfTask(TaskObject);
If Index >= 0 then
  begin
    If not(fTasks[Index].PublicPart.State in [tsRunning,tsPaused]) then
      begin
        If Assigned(fTasks[Index].AssignedThread) then
          begin
            fTasks[Index].AssignedThread.WaitFor;
            FreeAndNil(fTasks[Index].AssignedThread);
          end;
        If Assigned(fTasks[Index].CommEndpoint) then
          begin
            fTasks[Index].CommEndpoint.OnMessageTraversing := nil;
            FreeAndNil(fTasks[Index].CommEndpoint);
          end;
        fTasks[Index].PauseObject.Free;
        Result := fTasks[Index].PublicPart.TaskObject;
        For i := Index to Pred(High(fTasks)) do
          fTasks[i] := fTasks[i + 1];
        SetLength(fTasks,Length(fTasks) - 1);
      end
    else raise Exception.CreateFmt('TCNTSManager.ExtractTask: Cannot extract running task (#%d).',[Index]);
  end
else Result := nil;
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.ClearTasks;
var
  i:  Integer;
begin
For i := High(fTasks) downto Low(fTasks) do
  begin
    If fTasks[i].PublicPart.State in [tsRunning,tsPaused] then
      begin
        ResumeTask(i);
        fTasks[i].PublicPart.TaskObject.Terminated := True;
        fTasks[i].AssignedThread.WaitFor;
      end;
    fCommEndpoint.Cycle(0);
    DeleteTask(i);
  end;
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.ClearCompletedTasks;
var
  i:  Integer;
begin
Update;
For i := High(fTasks) downto Low(fTasks) do
  If fTasks[i].PublicPart.State = tsCompleted then
    DeleteTask(i);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.StartTask(TaskIndex: Integer);
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  case fTasks[TaskIndex].PublicPart.State of
    tsReady:
      begin
        fTasks[TaskIndex].PublicPart.State := tsRunning;
        fTasks[TaskIndex].AssignedThread :=
          TCNTSThread.Create(fTasks[TaskIndex].PublicPart.TaskObject,
                             fTasks[TaskIndex].CommEndpoint,
                             fTasks[TaskIndex].PauseObject);
        If Assigned(fOnTaskState) then
          fOnTaskState(Self,TaskIndex);
      end;
    tsWaiting,
    tsPaused:
      ResumeTask(TaskIndex);
  end
else raise Exception.CreateFmt('TCNTSManager.StartTask: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.PauseTask(TaskIndex: Integer);
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  case fTasks[TaskIndex].PublicPart.State of
    tsReady:
      fTasks[TaskIndex].PublicPart.State := tsWaiting;
    tsRunning:
      begin
        fTasks[TaskIndex].PublicPart.State := tsPaused;
        fTasks[TaskIndex].PauseObject.ResetEvent;
        If Assigned(fOnTaskState) then
          fOnTaskState(Self,TaskIndex);
        ManageRunningTasks;
      end;
  end
else raise Exception.CreateFmt('TCNTSManager.StartTask: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.ResumeTask(TaskIndex: Integer);
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  case fTasks[TaskIndex].PublicPart.State of
    tsWaiting:
      fTasks[TaskIndex].PublicPart.State := tsReady;
    tsPaused:
      begin
        fTasks[TaskIndex].PublicPart.State := tsRunning;
        fTasks[TaskIndex].PauseObject.SetEvent;
        If Assigned(fOnTaskState) then
          fOnTaskState(Self,TaskIndex);
      end;
  end
else raise Exception.CreateFmt('TCNTSManager.StartTask: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.StopTask(TaskIndex: Integer);
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  begin
    If fTasks[TaskIndex].PublicPart.State in [tsRunning,tsPaused] then
      begin
        fCommEndpoint.SendMessage(fTasks[TaskIndex].CommEndpoint.EndpointID,CNTS_MSG_TERMINATE,0,0,0);
        fTasks[TaskIndex].PublicPart.TaskObject.Terminated := True;
        ResumeTask(TaskIndex);
      end;
  end
else raise Exception.CreateFmt('TCNTSManager.StartTask: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

procedure TCNTSManager.WaitForRunningTasksToComplete;
var
  i:  Integer;
begin
For i := Low(fTasks) to High(fTasks) do
  If fTasks[i].PublicPart.State = tsRunning then
    fTasks[i].AssignedThread.WaitFor;
end;

//------------------------------------------------------------------------------

Function TCNTSManager.PostMessage(TaskIndex: Integer; Param1,Param2: TCNTSMessageParam): Boolean;
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  Result := fCommEndpoint.SendMessage(fTasks[TaskIndex].CommEndpoint.EndpointID,CNTS_MSG_USER,Param1,Param2,0)
else
  raise Exception.CreateFmt('TCNTSManager.PostMessage: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

Function TCNTSManager.SendMessage(TaskIndex: Integer; Param1,Param2: TCNTSMessageParam): TCNTSMessageResult;
begin
If (TaskIndex >= Low(fTasks)) and (TaskIndex <= High(fTasks)) then
  fCommEndpoint.SendMessage(fTasks[TaskIndex].CommEndpoint.EndpointID,CNTS_MSG_USER,Param1,Param2,{%H-}TMsgrParam(Addr(Result)))
else
  raise Exception.CreateFmt('TCNTSManager.PostMessage: Index (%d) out of bounds.',[TaskIndex]);
end;

//------------------------------------------------------------------------------

Function TCNTSManager.GetRunningTaskCount: Integer;
var
  i:  Integer;
begin
Result := 0;
For i := Low(fTasks) to High(fTasks) do
  If fTasks[i].PublicPart.State = tsRunning then
    Inc(Result);
end;

//------------------------------------------------------------------------------

Function TCNTSManager.GetActiveTaskCount(CountPaused: Boolean = False): Integer;
var
  i:  Integer;
begin
Result := 0;
For i := Low(fTasks) to High(fTasks) do
  begin
    If fTasks[i].PublicPart.State in [tsReady,tsRunning] then
      Inc(Result)
    else If CountPaused and (fTasks[i].PublicPart.State in [tsWaiting,tsPaused]) then
      Inc(Result);    
  end;
end;

end.
