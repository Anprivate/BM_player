unit bm_out;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  Winapi.Windows,
  Winapi.ActiveX, Winapi.DirectShow9,
  VCL.Forms, VCL.ExtCtrls,
  DeckLinkAPI, DeckLinkAPI.Modes, DeckLinkAPI.Discovery,
  global_types_unit, PreviewWindow;

type
  TBMOutput = class(TComponent, IDeckLinkVideoOutputCallback,
    IDeckLinkAudioOutputCallback)
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  private
    l_deckLink: IDeckLink;
    l_deckLinkOutput: IDeckLinkOutput;
    l_modeList: TList<IDeckLinkDisplayMode>;
    l_curMode: IDeckLinkDisplayMode;
    l_previewWindow: TPreviewWindow;
    //
    l_width: integer;
    l_height: integer;
    l_fps_num: integer; // aka timescale
    l_fps_den: integer; // aka frame duration
    l_interlaced: boolean;
    l_tff: boolean;
    l_max_channels: Int64;
    //
    l_debug: boolean;
    //
    l_scheduled_video_num: Int64;
    l_scheduled_audio_num: Int64;
    l_preroll: integer;
    l_current_position: Int64;
    l_current_pc: Int64;
    //
    l_playing_now: boolean;
    l_pause_mode: integer;
    l_preview_enabled: boolean;
    //
    InBMAVFrames: TTL_outAVframes;
    //
    procedure CheckAndRaiseIfFailed(hr: HResult; ErrorString: string);
    // video callbacks
    function ScheduledFrameCompleted(const completedFrame: IDeckLinkVideoFrame;
      results: _BMDOutputFrameCompletionResult): HResult; stdcall;
    function ScheduledPlaybackHasStopped: HResult; stdcall;
    function RenderAudioSamples(preroll: integer): HResult; stdcall;
    //
    // function CreateVideoFrame(InFrame: ToutAVFrame): IDeckLinkVideoFrame;
    function ScheduleFrame(InFrame: ToutAVFrame): HResult;
    //
    function frames_in_buffer_getter: integer;
    procedure AddToLog(instring: string);
  public
    OutputAVFrames: TTL_outAVframes;
    OutputText: TTLtext_list;
    //
    property debug: boolean write l_debug;
    //
    property out_width: integer read l_width;
    property out_height: integer read l_height;
    property out_fps_num: integer read l_fps_num;
    property out_fps_den: integer read l_fps_den;
    property out_interlaced: boolean read l_interlaced;
    property out_tff: boolean read l_tff;
    property out_max_channels: Int64 read l_max_channels;
    property current_position: Int64 read l_current_position;
    property current_pc: Int64 read l_current_pc;
    property deckLinkOutput: IDeckLinkOutput read l_deckLinkOutput;
    //
    property frames_in_buffer: integer read frames_in_buffer_getter;
    //
    function SelectDevice(CardNo: integer; modename: String): HResult;
    function DeselectDevice: HResult;
    //
    function SetPreview(PreviewPanel: TPanel): HResult;
    function ResetPreview(): HResult;
    //
    function ShowFrameSync(InFrame: ToutAVFrame): HResult;
    function StartPlayback(dl_buffer_size: integer): HResult;
    function StopPlayback: HResult;
    function ToPause: HResult;
    function FromPause: HResult;
    function ReadNextFrame: HResult;
    function IsInPause: boolean;
    //
    function DuplicateFrame(InFrame: ToutAVFrame; paused: boolean = false)
      : ToutAVFrame;
  end;

implementation

{ TBMOutput }
function TBMOutput.SelectDevice(CardNo: integer; modename: String): HResult;
var
  deckLinkIterator: IDeckLinkIterator;
  deckLinkDevice: IDeckLink;
  deckLinkAttributes: IDeckLinkAttributes;
  displayModeIterator: IDeckLinkDisplayModeIterator;
  DisplayMode: IDeckLinkDisplayMode;

  displayName, tmpModeName: wideString;
  m_BMDDisplayModeFlags: _BMDDisplayModeFlags;
  m_BMDFieldDominance: _BMDFieldDominance;
  FieldDominanceText, ColorSpaceText: string;
  m_frameDuration, m_timeScale: Int64;
  i: integer;

  DebugInfo: TStringList;
  tmpstr: string;
begin
  Result := E_FAIL;
  DebugInfo := nil;
  try
    DebugInfo := TStringList.Create;

    deckLinkIterator := nil;
    CheckAndRaiseIfFailed(CoCreateInstance(CLASS_CDeckLinkIterator, nil,
      CLSCTX_ALL, IID_IDeckLinkIterator, deckLinkIterator),
      'Decklink enumeration error - ');

    if l_debug then
      DebugInfo.Add('List of detected cards:');

    l_deckLink := nil;
    i := 1;
    while deckLinkIterator.Next(deckLinkDevice) = S_OK do
    begin
      if deckLinkDevice.GetDisplayName(displayName) <> S_OK then
        displayName := 'undetected';

      tmpstr := displayName;
      if i = CardNo then
      begin
        l_deckLink := deckLinkDevice;
        tmpstr := tmpstr + ' (selected)';
      end;

      if l_debug then
        DebugInfo.Add(tmpstr);

      AddToLog(tmpstr);

      inc(i);
    end;
    deckLinkIterator := nil;

    if not Assigned(l_deckLink) then
      raise Exception.Create('No decklink card with requested number');

    CheckAndRaiseIfFailed(l_deckLink.QueryInterface(IID_IDeckLinkAttributes,
      deckLinkAttributes),
      'Could not obtain the IDeckLinkAttributes interface');

    CheckAndRaiseIfFailed(deckLinkAttributes.GetInt
      (BMDDeckLinkMaximumAudioChannels, l_max_channels),
      'Get status BMDDeckLinkMaximumAudioChannels failed');

    CheckAndRaiseIfFailed(l_deckLink.QueryInterface(IID_IDeckLinkOutput,
      l_deckLinkOutput), 'Could not obtain the IDeckLinkOutput interface');

    l_modeList := TList<IDeckLinkDisplayMode>.Create;
    l_curMode := nil;

    if l_debug then
      DebugInfo.Add('List of detected modes:');

    CheckAndRaiseIfFailed(l_deckLinkOutput.GetDisplayModeIterator
      (displayModeIterator), 'Can not get mode iterator');

    while (displayModeIterator.Next(DisplayMode) = S_OK) do
    begin
      l_modeList.Add(DisplayMode);
      if l_debug then
      begin
        if FAILED(DisplayMode.GetName(tmpModeName)) then
          tmpModeName := 'unknown';

        if SameText(tmpModeName, modename) then
        begin
          l_curMode := DisplayMode;
          tmpstr := ' (selected)';
        end
        else
          tmpstr := '';

        DisplayMode.GetFrameRate(m_frameDuration, m_timeScale);

        m_BMDFieldDominance := DisplayMode.GetFieldDominance;
        case m_BMDFieldDominance of
          bmdUnknownFieldDominance:
            FieldDominanceText := 'UNK';
          bmdLowerFieldFirst:
            FieldDominanceText := 'BFF';
          bmdUpperFieldFirst:
            FieldDominanceText := 'TFF';
          bmdProgressiveFrame:
            FieldDominanceText := 'P';
          bmdProgressiveSegmentedFrame:
            FieldDominanceText := 'PsF';
        end;

        m_BMDDisplayModeFlags := DisplayMode.GetFlags;
        if (m_BMDDisplayModeFlags and bmdDisplayModeColorspaceRec601) <> 0 then
          ColorSpaceText := 'rec601';
        if (m_BMDDisplayModeFlags and bmdDisplayModeColorspaceRec709) <> 0 then
          ColorSpaceText := 'rec709';

        DebugInfo.Add(format('%18s / %4d x %4d %5.3f / %3s / %s / %s',
          [tmpModeName, DisplayMode.GetWidth, DisplayMode.GetHeight,
          m_timeScale / m_frameDuration, FieldDominanceText, ColorSpaceText,
          tmpstr]));
      end;
    end;

    if not Assigned(l_curMode) then
      raise Exception.Create('Can''t find requested mode ' + modename);

    l_width := l_curMode.GetWidth;
    l_height := l_curMode.GetHeight;

    l_curMode.GetFrameRate(m_frameDuration, m_timeScale);
    l_fps_num := m_timeScale;
    l_fps_den := m_frameDuration;

    m_BMDFieldDominance := l_curMode.GetFieldDominance;

    l_interlaced := true;
    l_tff := false;

    case m_BMDFieldDominance of
      bmdUnknownFieldDominance:
        l_interlaced := false;
      bmdLowerFieldFirst:
        l_tff := false;
      bmdUpperFieldFirst:
        l_tff := true;
      bmdProgressiveFrame:
        l_interlaced := false;
      bmdProgressiveSegmentedFrame:
        l_interlaced := false;
    end;

    if l_preview_enabled then
      CheckAndRaiseIfFailed(l_deckLinkOutput.SetScreenPreviewCallback
        (l_previewWindow), 'Set preview callback failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.SetScheduledFrameCompletionCallback
      (Self), 'Set frame completion callback failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.SetAudioCallback(Self),
      'Set audio callback failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.EnableVideoOutput
      (l_curMode.GetDisplayMode(), bmdVideoOutputFlagDefault),
      'Enable video output failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.EnableAudioOutput
      (bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger, l_max_channels,
      bmdAudioOutputStreamTimestamped), 'Enable audio output failed');

    Result := S_OK;
  except
    on E: Exception do
      AddToLog(E.Message)
    else
      AddToLog('Неизвестная ошибка');
  end;

  if Assigned(DebugInfo) then
  begin
    if DebugInfo.Count > 0 then
      DebugInfo.SaveToFile(ExtractFilePath(paramstr(0)) + 'card_info.txt');
    DebugInfo.Free;
  end;

end;

function TBMOutput.DeselectDevice: HResult;
begin
  Result := E_FAIL;
  try
    CheckAndRaiseIfFailed(l_deckLinkOutput.DisableAudioOutput,
      'Disable audio output failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.DisableVideoOutput,
      'Disable video output failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.SetScreenPreviewCallback(nil),
      'Set preview callback to nil failed');

    CheckAndRaiseIfFailed(l_deckLinkOutput.SetScheduledFrameCompletionCallback
      (nil), 'Set frame completion callback to nil failed');

    Result := S_OK;
  except
    on E: Exception do
      AddToLog(E.Message)
    else
      AddToLog('Неизвестная ошибка');
  end;
end;

function TBMOutput.SetPreview(PreviewPanel: TPanel): HResult;
begin
  Result := S_OK;
  // Create and initialise preview
  l_previewWindow := TPreviewWindow.Create;
  if (l_previewWindow.init(PreviewPanel) = false) then
  begin
    AddToLog('This application was unable to initialise the preview window');
    Result := E_FAIL;
    Exit;
  end;
end;

function TBMOutput.ResetPreview: HResult;
begin
  Result := E_FAIL;
  try
    l_previewWindow.Free;

    Result := S_OK;
  except
    on E: Exception do
      AddToLog(E.Message)
    else
      AddToLog('Неизвестная ошибка');
  end;
end;

function TBMOutput.ShowFrameSync(InFrame: ToutAVFrame): HResult;
var
  tmpFrame: IDeckLinkMutableVideoFrame;
begin
  Result := E_FAIL;

  if not Assigned(l_deckLinkOutput) then
    Exit;

  try
    {
      tmpFrame := CreateVideoFrame(InFrame);

      if not Assigned(tmpFrame) then
      raise Exception.Create('frame not created'); }

    CheckAndRaiseIfFailed(l_deckLinkOutput.DisplayVideoFrameSync
      (InFrame.VideoFrame), 'Can''t show frame');

    Result := S_OK;
  except
    on E: Exception do
      AddToLog(E.Message)
    else
      AddToLog('Неизвестная ошибка');
  end;
end;

function TBMOutput.StartPlayback(dl_buffer_size: integer): HResult;
var
  i: integer;
  vdata, tmpptr: PByte;
  tmpFrame: IDeckLinkMutableVideoFrame;
  tmp_dl_data: Pointer;
  displayDuration, displayTime, timeScale: Int64;
begin
  Result := E_FAIL;

  if l_playing_now then
    Exit;

  if not Assigned(l_deckLinkOutput) then
    Exit;

  if not Assigned(OutputAVFrames) then
    Exit;

  l_scheduled_video_num := 0;
  l_scheduled_audio_num := 0;
  l_preroll := dl_buffer_size;

  // create black frame
  GetMem(vdata, l_width * l_height * 2);
  tmpptr := vdata;

  for i := 0 to (l_width * l_height) - 1 do
  begin
    tmpptr^ := 128;
    inc(tmpptr);
    tmpptr^ := 16;
    inc(tmpptr);
  end;

  // send dl_buffer_size frames to decklink as scheduled frames
  try
    for i := 0 to dl_buffer_size - 1 do
    begin
      // create new DL frame
      CheckAndRaiseIfFailed(l_deckLinkOutput.CreateVideoFrame(l_width, l_height,
        l_width * 2, bmdFormat8BitYUV, bmdFrameFlagDefault, tmpFrame),
        'Cannot create output video frame');

      // get pointer to data part
      CheckAndRaiseIfFailed(tmpFrame.GetBytes(tmp_dl_data),
        'Cannot get pointer to data in temporary frame');

      // copy black frame to data part
      Move(vdata^, tmp_dl_data^, tmpFrame.GetRowBytes * tmpFrame.GetHeight);

      // fill time data and points
      displayDuration := l_fps_den;
      displayTime := l_scheduled_video_num * displayDuration;
      timeScale := l_fps_num;

      // schedule video frame
      CheckAndRaiseIfFailed(l_deckLinkOutput.ScheduleVideoFrame(tmpFrame,
        displayTime, displayDuration, timeScale),
        'Cannot schedule video frame');

      inc(l_scheduled_video_num, 1);
    end;

    // start audio preroll
    CheckAndRaiseIfFailed(l_deckLinkOutput.BeginAudioPreroll,
      'Cannot start audio preroll');

    Result := S_OK;
  except
    on E: Exception do
      AddToLog(E.Message)
    else
      AddToLog('Playback start - unknown error');
  end;

  FreeMem(vdata);
end;

function TBMOutput.StopPlayback: HResult;
var
  tmpr: Int64;
begin
  Result := E_FAIL;

  if l_playing_now then
  begin
    Result := l_deckLinkOutput.StopScheduledPlayback(0, tmpr, 0);
    l_playing_now := false;
  end;
end;

function TBMOutput.ToPause: HResult;
begin
  if l_pause_mode = 0 then
    l_pause_mode := 1;
end;

function TBMOutput.ReadNextFrame: HResult;
begin
  if l_pause_mode = 2 then
    l_pause_mode := 1;
end;

function TBMOutput.FromPause: HResult;
begin
  // AddToLog('Procedure FromPause');
  l_pause_mode := 0;
end;

function TBMOutput.IsInPause: boolean;
begin
  Result := l_pause_mode = 2;
end;

constructor TBMOutput.Create(AOwner: TComponent);
begin
  inherited; // Create(AOwner);

  InBMAVFrames := TTL_outAVframes.Create;
  l_playing_now := false;
  l_preview_enabled := true;
end;

function TBMOutput.ScheduleFrame(InFrame: ToutAVFrame): HResult;
var
  displayTime, displayDuration, timeScale: Int64;
  tmp_result: Cardinal;
  ares, vres: HResult;
  curr_frame_num, next_frame_num, curr_sample_num, next_sample_num: Int64;
  curr_sample_size: Int64;
  tmp_audio_ptr: PData16;
  i: integer;
begin
  Result := E_FAIL;

  if not Assigned(l_deckLinkOutput) then
    Exit;

  displayDuration := l_fps_den;
  displayTime := l_scheduled_video_num * displayDuration;
  timeScale := l_fps_num;

  vres := l_deckLinkOutput.ScheduleVideoFrame(InFrame.VideoFrame, displayTime,
    displayDuration, timeScale);
  curr_frame_num := l_scheduled_video_num;
  inc(l_scheduled_video_num, 1);
  next_frame_num := l_scheduled_video_num;

  // audio frame creation
  curr_sample_num := curr_frame_num * l_fps_den * 48000 div l_fps_num;
  next_sample_num := next_frame_num * l_fps_den * 48000 div l_fps_num;
  curr_sample_size := next_sample_num - curr_sample_num;

  // // 29,976 fps correction (different samples number in different frames
  if curr_sample_size <= InFrame.duration then
  begin
    // if input frame size is same or less then incoming - send data
    ares := l_deckLinkOutput.ScheduleAudioSamples(InFrame.AudioData,
      curr_sample_size, l_scheduled_audio_num, 48000, tmp_result);
    inc(l_scheduled_audio_num, curr_sample_size);
  end
  else
  begin
    // adding extra samples in end
    GetMem(tmp_audio_ptr, curr_sample_size * l_max_channels * 2);
    // copy actual data
    Move(InFrame.AudioData^, tmp_audio_ptr^, InFrame.duration *
      l_max_channels * 2);

    // duplicating last sample
    for i := InFrame.duration to curr_sample_size - 1 do
    begin
      Move(InFrame.AudioData[l_max_channels * (InFrame.duration - 1)],
        tmp_audio_ptr[i], l_max_channels * 2);
    end;

    ares := l_deckLinkOutput.ScheduleAudioSamples(tmp_audio_ptr,
      curr_sample_size, l_scheduled_audio_num, 48000, tmp_result);
    inc(l_scheduled_audio_num, curr_sample_size);

    // reaplacing audio in frame
    FreeMem(InFrame.AudioData);
    InFrame.AudioData := tmp_audio_ptr;
    InFrame.duration := curr_sample_size;
  end;

  if (vres = S_OK) and (ares = S_OK) then
    Result := S_OK
  else
    case ares of
      E_INVALIDARG:
        AddToLog('E_INVALIDARG');
      E_FAIL:
        AddToLog('E_FAIL');
      E_ACCESSDENIED:
        AddToLog('E_ACCESSDENIED');
    end;
end;

destructor TBMOutput.Destroy;
var
  tmp_list: TL_outAVframes;
  tmp_frame: ToutAVFrame;
begin
  tmp_list := InBMAVFrames.LockList;
  while tmp_list.Count > 0 do
  begin
    tmp_frame := tmp_list.Items[0];
    tmp_frame.Free;
    tmp_list.Delete(0);
  end;
  InBMAVFrames.UnlockList;

  InBMAVFrames.Free;

  inherited Destroy;
end;

function TBMOutput.DuplicateFrame(InFrame: ToutAVFrame; paused: boolean)
  : ToutAVFrame;
var
  tmp_frame: ToutAVFrame;
  i: integer;
  tmpptr_src, tmpptr_dst: Pointer;
  tmpptr_src_pb, tmpptr_dst_pb: PByte;
begin
  tmp_frame := ToutAVFrame.Create;

  tmp_frame.frame_number := InFrame.frame_number;
  tmp_frame.start_sample := InFrame.start_sample;
  tmp_frame.duration := InFrame.duration;

  CheckAndRaiseIfFailed(l_deckLinkOutput.CreateVideoFrame(l_curMode.GetWidth,
    l_curMode.GetHeight, l_curMode.GetWidth * 2, bmdFormat8BitYUV,
    bmdFrameFlagDefault, tmp_frame.VideoFrame),
    'Cannot create output video frame');

  CheckAndRaiseIfFailed(tmp_frame.VideoFrame.GetBytes(tmpptr_dst),
    'Cannot get pointer to data in temporary frame');

  CheckAndRaiseIfFailed(InFrame.VideoFrame.GetBytes(tmpptr_src),
    'Cannot get pointer to data in input frame');

  tmp_frame.AudioData := AllocMem(tmp_frame.duration * l_max_channels * 2);

  if paused and l_interlaced then
  begin
    tmpptr_src_pb := tmpptr_src;
    tmpptr_dst_pb := tmpptr_dst;
    // doubling lines for interlaced video
    for i := 0 to (l_height div 2) - 1 do
    begin
      Move(tmpptr_src_pb^, tmpptr_dst_pb^, l_width * 2);
      inc(tmpptr_dst_pb, l_width * 2);
      Move(tmpptr_src_pb^, tmpptr_dst_pb^, l_width * 2);
      inc(tmpptr_dst_pb, l_width * 2);
      inc(tmpptr_src_pb, l_width * 4);
    end;
  end
  else
  begin
    Move(tmpptr_src^, tmpptr_dst^, l_width * l_height * 2);
    Move(InFrame.AudioData^, tmp_frame.AudioData^,
      tmp_frame.duration * l_max_channels * 2);
  end;

  Result := tmp_frame;
end;

function TBMOutput.frames_in_buffer_getter: integer;
var
  fr_n: Cardinal;
begin
  Result := -1;

  if not Assigned(l_deckLinkOutput) then
    Exit;

  if l_deckLinkOutput.GetBufferedVideoFrameCount(fr_n) = S_OK then
    Result := fr_n;
end;

// callbacks
function TBMOutput.ScheduledFrameCompleted(const completedFrame
  : IDeckLinkVideoFrame; results: _BMDOutputFrameCompletionResult): HResult;
var
  tmp_list: TL_outAVframes;
  tmp_frame: ToutAVFrame;
  next_frame, last_used_frame, compl_frame: ToutAVFrame;
  isCompleted: boolean;
  i: integer;
begin
  // locking decklink mirror list
  tmp_list := InBMAVFrames.LockList;

  // searching for original frame for completed and free memory
  compl_frame := nil;
  for i := 0 to tmp_list.Count - 1 do
  begin
    tmp_frame := tmp_list.Items[i];
    if tmp_frame.VideoFrame = completedFrame then
    begin
      compl_frame := tmp_frame;
      break;
    end;
  end;

  // clearing
  if Assigned(compl_frame) then
  begin
    // current position and timestamp got
    l_current_position := compl_frame.frame_number;
    l_deckLinkOutput.GetFrameCompletionReferenceTimestamp
      (compl_frame.VideoFrame, 1000, l_current_pc);

    // clear frames in mirror buffer up to completed frame (including completed frame)
    isCompleted := false;
    while tmp_list.Count > 0 do
    begin
      tmp_frame := tmp_list.Items[0];
      if tmp_frame = compl_frame then
        isCompleted := true;

      tmp_frame.Free;
      tmp_list.Delete(0);

      if isCompleted then
        break;
    end;
  end
  else
  begin
    // precautions - clear all extra frames in mirror buffer
    // even if frame was not found
    while tmp_list.Count > (l_preroll * 2) do
    begin
      tmp_frame := tmp_list.Items[0];
      tmp_frame.Free;
      tmp_list.Delete(0);
    end;
  end;

  // last frame in list is last_used
  last_used_frame := nil;
  if tmp_list.Count > 0 then
    last_used_frame := tmp_list.Items[tmp_list.Count - 1];

  InBMAVFrames.UnlockList;

  // if we in pause and frame was sent - we don't need next frame
  next_frame := nil;
  if l_pause_mode <> 2 then
  begin
    // getting next frame
    tmp_list := OutputAVFrames.LockList;
    if tmp_list.Count > 0 then
    begin
      next_frame := tmp_list.Items[0];
      tmp_list.Delete(0);
    end;
    OutputAVFrames.UnlockList;
  end;

  // repeating the frame in pause mode
  // stopped frame was already sent, so repeat last sent frame
  if (l_pause_mode = 2) and Assigned(last_used_frame) then
    next_frame := DuplicateFrame(last_used_frame);

  if l_pause_mode = 1 then
  begin
    // first frame for stopped
    if Assigned(next_frame) then
    begin
      tmp_frame := DuplicateFrame(next_frame, true);
      next_frame.Free;
      next_frame := tmp_frame;
      l_pause_mode := 2;
      // AddToLog('pause_mode 1->2');
    end
    else
      AddToLog('Buffer is empty - cannot enter in pause');
  end;

  if not Assigned(next_frame) then
  begin
    if Assigned(last_used_frame) then
    begin
      // AddToLog('Buffer is empty - last frame repeated');
      next_frame := DuplicateFrame(last_used_frame, true);
      l_pause_mode := 2;
    end
    else
    begin
      AddToLog('Buffer is empty and nothing to repeat');
      StopPlayback;
    end;
  end;

  if l_playing_now and Assigned(next_frame) then
  begin
    ScheduleFrame(next_frame);
    InBMAVFrames.Add(next_frame);
  end;
  Result := S_OK;
end;

function TBMOutput.ScheduledPlaybackHasStopped: HResult;
begin
  Result := S_OK;
end;

function TBMOutput.RenderAudioSamples(preroll: integer): HResult;
var
  i: integer;
  start_sample_num, end_sample_num, duration_in_samples: Int64;
  data_buff: PByte;
  tmp_result: Cardinal;
begin
  if preroll <> 0 then
  begin
    // generating and sending audio to decklink
    for i := 0 to l_preroll - 1 do
    begin
      start_sample_num := (i * 48000 * l_fps_den) div l_fps_num;
      end_sample_num := ((i + 1) * 48000 * l_fps_den) div l_fps_num;
      duration_in_samples := end_sample_num - start_sample_num;

      data_buff := AllocMem(duration_in_samples * l_max_channels * 2);

      l_deckLinkOutput.ScheduleAudioSamples(data_buff, duration_in_samples,
        l_scheduled_audio_num, 48000, tmp_result);

      inc(l_scheduled_audio_num, duration_in_samples);
    end;

    // audio data sent, so preroll ended
    l_deckLinkOutput.EndAudioPreroll;

    // start playback
    l_deckLinkOutput.StartScheduledPlayback(0, l_fps_num, 1.0);

    l_playing_now := true;
  end;
  Result := S_OK;
end;

// others utilities
procedure TBMOutput.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

procedure TBMOutput.CheckAndRaiseIfFailed(hr: HResult; ErrorString: string);
var
  ErrMsg: string;
begin
  if FAILED(hr) then
  begin
    SetLength(ErrMsg, 512);
    AMGetErrorText(hr, PChar(ErrMsg), 512);
    raise Exception.Create(ErrorString + Trim(ErrMsg));
  end;
end;

end.
