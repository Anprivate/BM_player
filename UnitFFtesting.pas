unit UnitFFtesting;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, System.IniFiles, System.StrUtils, System.IOUtils,
  Vcl.Graphics, Vcl.ExtCtrls, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ComCtrls,
  global_types_unit, ff_reader, frame_feeder_thread, bm_out;

type
  TIni_params = record
    card_no: integer;
    card_mode: string;
    //
    main_buffer: integer;
    preload: integer;
    //
    filename: string;
    in_point: Int64;
    out_point: Int64;
    file_start_point: Int64;
    //
    slave_mode: boolean;
    chase_correction: Int64;
  end;

  TFormBMFFplayer = class(TForm)
    Memo1: TMemo;
    Timer1: TTimer;
    LabelO: TLabel;
    PanelPreview: TPanel;
    ProgressBarBuffer: TProgressBar;
    LabelFileName: TLabel;
    PanelPositions: TPanel;
    PanelTCin: TPanel;
    TrackBarPosition: TTrackBar;
    PanelTCposition: TPanel;
    PanelTCout: TPanel;
    PanelChase: TPanel;
    LabelIncomingTC: TLabel;
    PanelIncomingTC: TPanel;
    LabelDifference: TLabel;
    PanelDifference: TPanel;
    LabelPS: TLabel;
    LabelCS: TLabel;
    procedure Timer1Timer(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormResize(Sender: TObject);
    procedure WndProc(var Message: TMessage); override;
  private
    Ini_params: TIni_params;
    OutputText: TTLtext_list;
    OutputAVFrames: TTL_outAVframes;
    // unit frame feeder
    frame_feeder: TFrame_feeder;
    commands_list: TTLcommand_list;
    // unit blackmagic output
    BM_output: TBMOutput;
    //
    MsgTCServer: Cardinal;
    in_timer_pause_stage: integer;
    in_timer_chasing_stage: integer;
    prev_pause_stage: integer;
    prev_chasing_stage: integer;
    prev_pause_state: boolean;
    jump_position: Int64;
    pause_after_jump: boolean;
    last_diff_in_ms: Int64;
    correction_in_frames: Int64;
    last_repeated_frame_position: Int64;
    pause_initiated: boolean;
    last_correction_was_fine: boolean;
    // frame_feeder control
    procedure prOpenFile(infilename: string);
    procedure prCloseFile;
    procedure prSendJump(FrameNum: Int64; clear_buffer: boolean = false);
    procedure prSendSetInOut(inpoint, outpoint: Int64);
    // decklink control
    procedure prOpenDecklink;
    procedure prCloseDecklink;
    procedure prStartPlaying;
    procedure prStopPlaying;
    procedure prShowFrame(in_frame: ToutAVFrame);
    //
    procedure in_timer_pause_process;
    procedure in_timer_chase_process;
    procedure JumpAndPause(position: Int64);
    procedure JumpAndPlay(position: Int64);
    // other
    procedure prClearBuffer;
    procedure prWaitFullBuffer;
    function TryStringToTC(InString: string; fps_num: Int64; fps_den: Int64;
      var TC: Int64): boolean;
    function TCtoString(inTC: Int64; fps_num: Int64; fps_den: Int64): string;
    procedure AddToLog(InString: string);
  public
    { Public declarations }
  end;

var
  FormBMFFplayer: TFormBMFFplayer;

implementation

{$R *.dfm}

// ======= Main form procedures
procedure TFormBMFFplayer.FormCreate(Sender: TObject);
var
  Ini: TIniFile;
  tmpstr, tmpipt, tmpopt, tmpsfpt: string;
  widescreen: boolean;
  oldh: integer;
  tmptc: Int64;
  BuildTime: TDateTime;
begin
  Memo1.Clear;
  Self.DoubleBuffered := true;

  Ini := TIniFile.Create(extractfilepath(ParamStr(0)) + 'settings.ini');
  try
    Ini_params.card_no := Ini.ReadInteger('decklink', 'number', 1);
    Ini_params.card_mode := Ini.ReadString('decklink', 'mode', '1080i50');
    Ini_params.preload := Ini.ReadInteger('decklink', 'preload', 5);
    //
    Ini_params.main_buffer := Ini.ReadInteger('reader', 'buffer', 25);
    tmpipt := Ini.ReadString('reader', 'in', '-1');
    tmpopt := Ini.ReadString('reader', 'out', '-1');
    //
    Ini_params.slave_mode := Ini.ReadBool('common', 'slave_mode', false);
    Ini_params.chase_correction := Ini.ReadInteger('common',
      'chase_correction', 0);
    Ini_params.filename := Ini.ReadString('common', 'filename', '');
    widescreen := Ini.ReadBool('common', 'widescreen', false);
    tmpsfpt := Ini.ReadString('common', 'file_start_timecode', '-1');

    Self.Left := Ini.ReadInteger('position', 'left', Self.Left);
    Self.Top := Ini.ReadInteger('position', 'top', Self.Top);
    Self.Width := Ini.ReadInteger('position', 'width', Self.Width);
    Self.Height := Ini.ReadInteger('position', 'height', Self.Height);
  finally
    Ini.Free;
  end;

  BuildTime := TFile.GetLastWriteTime(ParamStr(0));
  if Ini_params.slave_mode then
    tmpstr := 'slave mode'
  else
    tmpstr := 'cycle mode';
  Self.Caption := 'Decklink #' + Ini_params.card_no.ToString + ' - ' + tmpstr +
    ' (build ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', BuildTime) + ')';

  OutputText := TTLtext_list.Create;
  OutputAVFrames := TTL_outAVframes.Create;
  commands_list := TTLcommand_list.Create;

  in_timer_pause_stage := 0;
  in_timer_chasing_stage := 0;

  if not fileExists(Ini_params.filename) then
    Exit;

  LabelFileName.Caption := Ini_params.filename;

  PanelChase.Enabled := Ini_params.slave_mode;
  PanelChase.Visible := Ini_params.slave_mode;

  oldh := PanelPreview.Height;
  if widescreen then
    PanelPreview.Height := PanelPreview.Width * 9 div 16
  else
    PanelPreview.Height := PanelPreview.Width * 3 div 4;

  PanelPreview.Top := PanelPreview.Top + (oldh - PanelPreview.Height) div 2;

  // open decklink
  prOpenDecklink;
  if not Assigned(BM_output) then
    Exit;

  // open reader
  prOpenFile(Ini_params.filename);
  if not Assigned(frame_feeder) then
    Exit;

  tmptc := -1;
  // processing start file timecode
  if not TryStringToTC(tmpsfpt, BM_output.out_fps_num, BM_output.out_fps_den,
    tmptc) then
    tmptc := -1;

  if tmptc < 0 then
    if (frame_feeder.file_timecode = '') or
      not TryStringToTC(frame_feeder.file_timecode, BM_output.out_fps_num,
      BM_output.out_fps_den, tmptc) then
      tmptc := 0;

  if tmptc < 0 then
    tmptc := 0;

  Ini_params.file_start_point := tmptc;

  // processing in point
  if not Ini_params.slave_mode and TryStringToTC(tmpipt, BM_output.out_fps_num,
    BM_output.out_fps_den, tmptc) then
    if tmptc < 0 then
      Ini_params.in_point := 0
    else
      Ini_params.in_point := tmptc - Ini_params.file_start_point
  else
    Ini_params.in_point := 0;

  // in point is too close to end of file
  if Ini_params.in_point > (frame_feeder.file_duration - 50) then
    Ini_params.in_point := 0;

  // processing out point
  if not Ini_params.slave_mode and TryStringToTC(tmpopt, BM_output.out_fps_num,
    BM_output.out_fps_den, tmptc) then
    if tmptc < 0 then
      Ini_params.out_point := frame_feeder.file_duration
    else
      Ini_params.out_point := tmptc - Ini_params.file_start_point
  else
    Ini_params.out_point := frame_feeder.file_duration;

  // out point is out the end of file
  if Ini_params.out_point > frame_feeder.file_duration then
    Ini_params.out_point := frame_feeder.file_duration;

  // in point is larger then out point
  if Ini_params.in_point > Ini_params.out_point then
  begin
    Ini_params.in_point := 0;
    Ini_params.out_point := frame_feeder.file_duration;
  end;

  PanelTCin.Caption := TCtoString(Ini_params.in_point +
    Ini_params.file_start_point, BM_output.out_fps_num, BM_output.out_fps_den);

  PanelTCout.Caption := TCtoString(Ini_params.out_point +
    Ini_params.file_start_point, BM_output.out_fps_num, BM_output.out_fps_den);

  TrackBarPosition.Max := frame_feeder.file_duration;
  TrackBarPosition.SelStart := Ini_params.in_point;
  TrackBarPosition.SelEnd := Ini_params.out_point;

  prSendSetInOut(Ini_params.in_point, Ini_params.out_point);
  prSendJump(Ini_params.in_point, true);

  prWaitFullBuffer;

  prStartPlaying;

  MsgTCServer := RegisterWindowMessage('TimecodeServer');
  if MsgTCServer = 0 then
    AddToLog('TC server not registered')
  else
    AddToLog('TC server ID:' + inttohex(MsgTCServer));
end;

procedure TFormBMFFplayer.FormClose(Sender: TObject; var Action: TCloseAction);
var
  Ini: TIniFile;
begin
  prCloseDecklink;

  prCloseFile;

  OutputText.Free;
  OutputAVFrames.Free;
  commands_list.Free;

  Ini := TIniFile.Create(extractfilepath(ParamStr(0)) + 'settings.ini');
  try
    Ini.WriteInteger('position', 'left', Self.Left);
    Ini.WriteInteger('position', 'top', Self.Top);
    Ini.WriteInteger('position', 'width', Self.Width);
    Ini.WriteInteger('position', 'height', Self.Height);
  finally
    Ini.Free;
  end;
end;

procedure TFormBMFFplayer.FormResize(Sender: TObject);
var
  minwidth: integer;
begin
  if Self.ClientHeight < Memo1.Top + 50 then
    Self.ClientHeight := Memo1.Top + 50;

  minwidth := PanelPositions.Left + PanelTCin.Left + PanelTCin.Width +
    PanelTCin.Left + PanelTCposition.Width + PanelTCin.Left + PanelTCout.Width +
    PanelTCin.Left + Memo1.Left;
  if Self.ClientWidth < minwidth then
    Self.ClientWidth := minwidth;

  Memo1.Width := Self.ClientWidth - Memo1.Left * 2;
  Memo1.Height := Self.ClientHeight - Memo1.Top - Memo1.Left;
  PanelPositions.Width := Self.ClientWidth - PanelPositions.Left - Memo1.Left;
  PanelChase.Width := Self.ClientWidth - PanelChase.Left - Memo1.Left;

  TrackBarPosition.Width := PanelPositions.Width - TrackBarPosition.Left -
    TrackBarPosition.Left;

  PanelTCout.Left := PanelPositions.Width - PanelTCout.Width - PanelTCin.Left;

  PanelTCposition.Left := (PanelTCin.Left + PanelTCout.Left) div 2;

  PanelTCout.Left := PanelPositions.Width - PanelTCout.Width - PanelTCin.Left;
end;

// ======= BM_output
procedure TFormBMFFplayer.prOpenDecklink;
begin
  if Assigned(BM_output) then
    Exit;

  BM_output := TBMOutput.Create(Self);

  BM_output.OutputText := OutputText;
  BM_output.OutputAVFrames := OutputAVFrames;

  BM_output.debug := true;
  BM_output.SetPreview(PanelPreview);

  if Failed(BM_output.SelectDevice(Ini_params.card_no, Ini_params.card_mode))
  then
  begin
    AddToLog(Format('Карта #%d не может быть запущена в режиме %s',
      [Ini_params.card_no, Ini_params.card_mode]));
    BM_output.Free;
    BM_output := nil;
  end;
end;

procedure TFormBMFFplayer.prCloseDecklink;
begin
  if not Assigned(BM_output) then
    Exit;

  if Failed(BM_output.DeselectDevice) then
    AddToLog('Deselect failed');
  if Failed(BM_output.ResetPreview) then
    AddToLog('ResetPreview failed');
  BM_output.Free;
  BM_output := nil;
end;

procedure TFormBMFFplayer.prStartPlaying;
begin
  if not Assigned(BM_output) then
    Exit;

  if Ini_params.slave_mode then
    BM_output.ToPause;
  BM_output.StartPlayback(5);
end;

procedure TFormBMFFplayer.prStopPlaying;
begin
  if not Assigned(BM_output) then
    Exit;

  BM_output.StopPlayback;
end;

// ======= frame_feeder
procedure TFormBMFFplayer.prOpenFile(infilename: string);
begin
  if Assigned(frame_feeder) then
    Exit;

  if not Assigned(BM_output) then
    Exit;

  frame_feeder := TFrame_feeder.Create(true);
  frame_feeder.infilename := infilename;

  // copy parameters from selected decklink
  frame_feeder.Width := BM_output.out_width;
  frame_feeder.Height := BM_output.out_height;
  frame_feeder.fps_num := BM_output.out_fps_num;
  frame_feeder.fps_den := BM_output.out_fps_den;
  frame_feeder.interlaced := BM_output.out_interlaced;
  frame_feeder.tff := BM_output.out_tff;
  frame_feeder.out_channels := BM_output.out_max_channels;
  frame_feeder.deckLinkOutput := BM_output.deckLinkOutput;
  // other parameters
  frame_feeder.auto_loop := not Ini_params.slave_mode;
  frame_feeder.OutputText := OutputText;
  frame_feeder.OutputAVFrames := OutputAVFrames;
  frame_feeder.max_filled_frames := Ini_params.main_buffer;
  frame_feeder.commands_list := commands_list;

  frame_feeder.FreeOnTerminate := false;
  frame_feeder.Start;

  repeat
    Application.ProcessMessages;
  until frame_feeder.file_is_open or frame_feeder.Finished;

  if frame_feeder.Finished then
  begin
    frame_feeder.Free;
    frame_feeder := nil;
  end;
end;

procedure TFormBMFFplayer.prCloseFile;
begin
  if not Assigned(frame_feeder) then
    Exit;

  frame_feeder.Terminate;

  while not frame_feeder.Finished do
    Application.ProcessMessages;

  frame_feeder.Free;

  frame_feeder := nil;
end;

procedure TFormBMFFplayer.prSendJump(FrameNum: Int64;
  clear_buffer: boolean = false);
var
  tmp_command: Tcommand;
begin
  if not Assigned(frame_feeder) then
    Exit;

  tmp_command := Tcommand.Create;
  tmp_command.code := Tcommand_code.jump;
  tmp_command.in_point := FrameNum;
  if clear_buffer then
    tmp_command.out_point := 1
  else
    tmp_command.out_point := 0;

  commands_list.Add(tmp_command);
end;

procedure TFormBMFFplayer.prSendSetInOut(inpoint, outpoint: Int64);
var
  tmp_command: Tcommand;
begin
  if not Assigned(frame_feeder) then
    Exit;

  tmp_command := Tcommand.Create;
  tmp_command.code := Tcommand_code.auto_jump;
  tmp_command.in_point := inpoint;
  tmp_command.out_point := outpoint;
  commands_list.Add(tmp_command);
end;

procedure TFormBMFFplayer.prShowFrame(in_frame: ToutAVFrame);
begin
  if not Assigned(BM_output) then
    Exit;

  BM_output.ShowFrameSync(in_frame);
end;

// ======= other
procedure TFormBMFFplayer.Timer1Timer(Sender: TObject);
var
  tmp_log_list: TLtext_list;
  tmp_frame_list: TL_outAVframes;
  tmp_msg: TOne_text;
  frames_in_buffer: integer;
begin
  Timer1.Enabled := false;

  if Assigned(OutputText) then
  begin
    tmp_log_list := OutputText.LockList;
    while tmp_log_list.Count > 0 do
    begin
      tmp_msg := tmp_log_list.Items[0];
      tmp_log_list.Delete(0);

      Memo1.Lines.Add(tmp_msg.Text);
      if Memo1.Lines.Count > 200 then
        Memo1.Lines.Delete(0);
      tmp_msg.Free;
    end;
    OutputText.UnlockList;
  end;

  if Assigned(frame_feeder) then
  begin
    tmp_frame_list := OutputAVFrames.LockList;
    frames_in_buffer := tmp_frame_list.Count;
    OutputAVFrames.UnlockList;

    LabelO.Caption := inttostr(frames_in_buffer) + '/' +
      inttostr(Ini_params.main_buffer);
    ProgressBarBuffer.position := (ProgressBarBuffer.Max * frames_in_buffer)
      div Ini_params.main_buffer;
  end;

  if Assigned(BM_output) then
  begin
    PanelTCposition.Caption := TCtoString(BM_output.current_position +
      Ini_params.file_start_point, BM_output.out_fps_num,
      BM_output.out_fps_den);
    TrackBarPosition.position := BM_output.current_position;
  end;

  if pause_initiated and Assigned(BM_output) and (in_timer_chasing_stage = 0)
    and (in_timer_pause_stage = 0) then
  begin
    BM_output.ToPause;
    pause_initiated := false;
  end;

  if in_timer_pause_stage <> 0 then
  begin
    LabelPS.Visible := true;
    LabelPS.Caption := 'PS: ' + in_timer_pause_stage.ToString;
  end
  else
    LabelPS.Visible := false;

  if in_timer_chasing_stage <> 0 then
  begin
    LabelCS.Visible := true;
    LabelCS.Caption := 'CS: ' + in_timer_chasing_stage.ToString;
  end
  else
    LabelCS.Visible := false;

  in_timer_pause_process;

  in_timer_chase_process;

  {
    if in_timer_pause_stage <> prev_pause_stage then
    begin
    AddToLog(Format('Pause stage %d -> %d', [prev_pause_stage,
    in_timer_pause_stage]));
    prev_pause_stage := in_timer_pause_stage;
    end;

    if in_timer_chasing_stage <> prev_chasing_stage then
    begin
    AddToLog(Format('Chase stage %d -> %d', [prev_chasing_stage,
    in_timer_chasing_stage]));
    prev_chasing_stage := in_timer_chasing_stage;
    end;

    if Assigned(BM_output) and (prev_pause_state <> BM_output.IsInPause) then
    begin
    if BM_output.IsInPause then
    AddToLog('Pause state false -> true')
    else
    AddToLog('Pause state true -> false');
    prev_pause_state := BM_output.IsInPause;
    end;
  }
  Timer1.Enabled := true;
end;

procedure TFormBMFFplayer.in_timer_chase_process;
var
  dest_frame: Int64;
  tmp_list: TL_outAVframes;
  tmp_frame, new_frame: ToutAVFrame;

begin
  if (in_timer_chasing_stage = 0) or (in_timer_pause_stage <> 0) or
    not Assigned(BM_output) or not Assigned(frame_feeder) then
    Exit;

  case in_timer_chasing_stage of
    1: // got a difference, check and proceed
      begin
        correction_in_frames := last_diff_in_ms *
          BM_output.out_fps_num div BM_output.out_fps_den div 1000;

        if (last_diff_in_ms < 0) then
          dec(correction_in_frames);

        // big difference, we have to make a jump
        if Abs(last_diff_in_ms) > 2000 then
        begin
          // jump to curpos + 1.5 sec
          dest_frame := BM_output.current_position - correction_in_frames +
            (3 * BM_output.out_fps_num div BM_output.out_fps_den div 2);
          if (dest_frame >= 0) and
            (dest_frame < (frame_feeder.file_duration - 100)) then
          begin
            JumpAndPlay(dest_frame);
            in_timer_chasing_stage := 2;
          end
          else
            // correction impossible
            in_timer_chasing_stage := 0;
        end
        else
        begin
          last_repeated_frame_position := -1;
          in_timer_chasing_stage := 3;
        end;
      end;
    2: // waiting for end of jump
      begin
        if Abs(BM_output.current_position - jump_position) < 5 then
          in_timer_chasing_stage := 0;
      end;
    3: // difference is less then 2000 ms
      begin
        if correction_in_frames = 0 then
        begin
          // it was no correction
          if last_repeated_frame_position < 0 then
          begin
            in_timer_chasing_stage := 0;
          end
          else
          begin
            // was correction - waiting next frame in playout
            in_timer_chasing_stage := 4;
          end;
        end
        else
        begin
          // need to delete frames in queue
          if correction_in_frames < 0 then
          begin
            // if buffer is filled more than 75% - delete 1 frame from buffer
            tmp_list := OutputAVFrames.LockList;
            if tmp_list.Count > (Ini_params.main_buffer * 3 div 4) then
            begin
              tmp_frame := tmp_list.Items[0];
              tmp_list.Delete(0);
              if Assigned(tmp_frame) then
              begin
                last_repeated_frame_position := tmp_frame.frame_number;
                tmp_frame.Free;
              end;
            end;
            OutputAVFrames.UnlockList;
            inc(correction_in_frames);
          end
          else
          begin
            // repeat 1 frame in buffer
            tmp_list := OutputAVFrames.LockList;
            if (tmp_list.Count > 0) and
              (tmp_list.Count < Ini_params.main_buffer + 2) then
            begin
              tmp_frame := tmp_list.Items[0];
              new_frame := BM_output.DuplicateFrame(tmp_frame, false);

              if new_frame.frame_number > last_repeated_frame_position then
                last_repeated_frame_position := new_frame.frame_number;

              tmp_list.Insert(1, new_frame);
            end;
            OutputAVFrames.UnlockList;
            dec(correction_in_frames);
          end;
        end;
      end;
    4: // waiting for timecode
      begin
        if BM_output.current_position > (last_repeated_frame_position + 5) then
          in_timer_chasing_stage := 0;
      end;
  end;
end;

procedure TFormBMFFplayer.in_timer_pause_process;
var
  tmp_list: TL_outAVframes;
  tmp_frame: ToutAVFrame;
  i, f_frame_position: integer;
  isfilled: boolean;
begin
  if (in_timer_pause_stage = 0) or not Assigned(BM_output) or
    not Assigned(frame_feeder) then
    Exit;

  case in_timer_pause_stage of
    1: // blackmagic to pause
      begin
        if not BM_output.IsInPause then
          BM_output.ToPause;
        in_timer_pause_stage := 2;
      end;
    2: // blackmagic sent stop frame to buffer - send jump to feeder
      begin
        if BM_output.IsInPause then
        begin
          prSendJump(jump_position, true);
          in_timer_pause_stage := 3;
        end;
      end;
    3: // waiting for first frame with correct timecode
      begin
        tmp_list := OutputAVFrames.LockList;

        f_frame_position := -1;
        for i := 0 to tmp_list.Count - 1 do
        begin
          tmp_frame := tmp_list.Items[i];
          if tmp_frame.frame_number = jump_position then
          begin
            // AddToLog('Jump frame found');
            f_frame_position := i;
            in_timer_pause_stage := 4;
            break;
          end;
        end;

        // delete all frames before
        for i := 1 to f_frame_position do
        begin
          tmp_frame := tmp_list.Items[0];
          tmp_list.Delete(0);
          tmp_frame.Free;
        end;

        OutputAVFrames.UnlockList;
      end;
    4: // waiting for buffer filling
      begin
        tmp_list := OutputAVFrames.LockList;
        isfilled := tmp_list.Count > 5;
        OutputAVFrames.UnlockList;

        if isfilled then
        begin
          // initiate readin
          if pause_after_jump then
          begin
            BM_output.ReadNextFrame;
            in_timer_pause_stage := 5;
          end
          else
          begin
            BM_output.FromPause;
            in_timer_pause_stage := 0;
          end;
        end;
      end;
    5:
      begin
        if BM_output.IsInPause then
          in_timer_pause_stage := 0;
      end;
  end;
end;

procedure TFormBMFFplayer.JumpAndPause(position: Int64);
begin
  if (in_timer_pause_stage <> 0) or not Assigned(BM_output) or
    not Assigned(frame_feeder) then
    Exit;

  jump_position := position;
  pause_after_jump := true;
  in_timer_pause_stage := 1;
end;

procedure TFormBMFFplayer.JumpAndPlay(position: Int64);
begin
  if (in_timer_pause_stage <> 0) or not Assigned(BM_output) or
    not Assigned(frame_feeder) then
    Exit;

  jump_position := position;
  pause_after_jump := false;
  in_timer_pause_stage := 1;
end;

procedure TFormBMFFplayer.prClearBuffer;
var
  tmp_list: TL_outAVframes;
  tmp_frame: ToutAVFrame;
begin
  tmp_list := OutputAVFrames.LockList;
  while tmp_list.Count > 0 do
  begin
    tmp_frame := tmp_list.Items[0];
    tmp_list.Delete(0);

    if Assigned(tmp_frame) then
      tmp_frame.Free;
  end;
  OutputAVFrames.UnlockList;
end;

procedure TFormBMFFplayer.prWaitFullBuffer;
var
  tmp_list: TL_outAVframes;
  frames_in_buffer: integer;
begin
  repeat
    tmp_list := OutputAVFrames.LockList;
    frames_in_buffer := tmp_list.Count;
    OutputAVFrames.UnlockList;

    Application.ProcessMessages;
  until frames_in_buffer >= Ini_params.main_buffer;

end;

// ======= additional procedures
function TFormBMFFplayer.TCtoString(inTC, fps_num, fps_den: Int64): string;
var
  fullsec, iHours, iMinutes, iSeconds, iFrames, tmp: Int64;
begin
  fullsec := inTC * fps_den div fps_num;
  iFrames := inTC - (fullsec * fps_num div fps_den);

  tmp := fullsec;
  iHours := tmp div 3600;
  tmp := tmp mod 3600;

  iMinutes := tmp div 60;
  iSeconds := tmp mod 60;
  TCtoString := Format('%.2u', [iHours]) + ':' + Format('%.2u', [iMinutes]) +
    ':' + Format('%.2u', [iSeconds]) + ':' + Format('%.2u', [iFrames]);
end;

function TFormBMFFplayer.TryStringToTC(InString: string; fps_num: Int64;
  fps_den: Int64; var TC: Int64): boolean;
var
  tmpstr: string;
  iHours, iMin, iSec, iFrames, fullseconds: Int64;
  position: integer;
begin
  iHours := 0;
  iMin := 0;
  iSec := 0;

  tmpstr := ReverseString(InString);
  position := pos(':', tmpstr);
  if position > 0 then
  begin
    if not trystrtoint64(ReverseString(LeftStr(tmpstr, position - 1)), iFrames)
    then
      iFrames := -1;
    tmpstr := MidStr(tmpstr, position + 1, 1000);

    position := pos(':', tmpstr);
    if position > 0 then
    begin
      if not trystrtoint64(ReverseString(LeftStr(tmpstr, position - 1)), iSec)
      then
        iSec := -1;
      tmpstr := MidStr(tmpstr, position + 1, 1000);

      position := pos(':', tmpstr);
      if position > 0 then
      begin
        if not trystrtoint64(ReverseString(LeftStr(tmpstr, position - 1)), iMin)
        then
          iMin := -1;
        tmpstr := MidStr(tmpstr, position + 1, 1000);
        if not trystrtoint64(ReverseString(tmpstr), iHours) then
          iHours := -1;
      end
      else if not trystrtoint64(ReverseString(tmpstr), iMin) then
        iMin := -1;
    end
    else if not trystrtoint64(ReverseString(tmpstr), iSec) then
      iSec := -1;
  end
  else if not trystrtoint64(ReverseString(tmpstr), iFrames) then
    iFrames := -1;

  fullseconds := iSec + 60 * (iMin + 60 * iHours);
  TC := iFrames + (fullseconds * fps_num div fps_den);
  TryStringToTC := (iFrames >= 0) and (iSec >= 0) and (iMin >= 0) and
    (iHours >= 0);
end;

procedure TFormBMFFplayer.WndProc(var Message: TMessage);
var
  qpc, qpcfr, tcinms, tcinframes, curpos_in_ms: Int64;
  inEMUTC: Int64;
  ms_in_frame: Int64;
  isStrictDiff, isRelaxedDiff: boolean;
begin
  inherited;

  if (MsgTCServer = 0) or (Message.Msg <> MsgTCServer) or not Ini_params.slave_mode
  then
    Exit;

  case Message.WParam of
    1: // preroll command
      begin
        if (in_timer_pause_stage = 0) and (in_timer_chasing_stage = 0) then
        begin
          tcinms := Message.LParam;
          tcinframes :=
            (tcinms * BM_output.out_fps_num div (BM_output.out_fps_den * 1000))
            - Ini_params.file_start_point;

          if (tcinframes >= 0) and
            (tcinframes < (frame_feeder.file_duration - 50)) then
            JumpAndPause(tcinframes);
        end;
      end;
    2: // chase command
      begin
        if Assigned(BM_output) then
        begin
          QueryPerformanceCounter(qpc);
          QueryPerformanceFrequency(qpcfr);

          // получаем входную позицию в ms
          tcinms := (qpc div (qpcfr div 1000)) - Message.LParam;

          // пересчитываем входную позицию в кадры
          inEMUTC := tcinms * BM_output.out_fps_num div BM_output.
            out_fps_den div 1000;

          // выдаём на индикацию
          PanelIncomingTC.Caption := TCtoString(inEMUTC, BM_output.out_fps_num,
            BM_output.out_fps_den);

          // пересчитываем текущую позицию воспроизведения в ms
          curpos_in_ms :=
            (BM_output.current_position + Ini_params.file_start_point) * 1000 *
            BM_output.out_fps_den div BM_output.out_fps_num;

          // получаем желаемую позицию в ms в данный момент
          tcinms := BM_output.current_pc - Message.LParam;

          // считаем разницу в мс с учётом коррекции
          last_diff_in_ms := curpos_in_ms - tcinms +
            Ini_params.chase_correction;

          // выдаём эту разницу на индикацию
          PanelDifference.Caption := inttostr(last_diff_in_ms);

          // грубая прикидка количества ms в одном кадре
          ms_in_frame := 1000 * BM_output.out_fps_den div BM_output.out_fps_num;

          // from 0 to 1 frame
          isStrictDiff := (last_diff_in_ms >= 0) and
            (last_diff_in_ms < ms_in_frame);

          // from -1 to 2 frame
          isRelaxedDiff := (last_diff_in_ms >= (-ms_in_frame)) and
            (last_diff_in_ms < (2 * ms_in_frame));

          // we can do correction
          if (inEMUTC > Ini_params.file_start_point) and
            (inEMUTC < (Ini_params.file_start_point + frame_feeder.file_duration
            - 50)) and (in_timer_pause_stage = 0) and
            (in_timer_chasing_stage = 0) then
          begin
            // there is no need to do correction
            if isStrictDiff then
            begin
              last_correction_was_fine := true;
            end
            else
            begin
              // big difference - start correction anyway
              if not isRelaxedDiff then
              begin
                if BM_output.IsInPause then
                  BM_output.FromPause;

                in_timer_chasing_stage := 1;
                last_correction_was_fine := false;
              end
              else
              begin
                // difference is less then 2 frames
                if not last_correction_was_fine then
                begin
                  if BM_output.IsInPause then
                    BM_output.FromPause;
                  in_timer_chasing_stage := 1;
                  last_correction_was_fine := true;
                end;
              end;
            end;
          end;
        end;
      end;
    3:
      // stop command
      begin
        pause_initiated := true;
      end;
  else
    AddToLog('MSG: $' + Message.WParam.ToHexString + ' $' +
      Message.LParam.ToHexString);
  end;
end;

procedure TFormBMFFplayer.AddToLog(InString: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(InString));
end;

end.
