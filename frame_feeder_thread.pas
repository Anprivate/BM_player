unit frame_feeder_thread;

interface

uses
  System.Classes, System.Generics.Collections, DeckLinkAPI,
  global_types_unit, ff_reader;

type
  // commands
  Tcommand_code = (jump, auto_jump);

  Tcommand = class(TObject)
    code: Tcommand_code;
    in_point: int64;
    out_point: int64;
  end;

  TTLcommand_list = TThreadList<Tcommand>;
  TLcommand_list = TList<Tcommand>;

  // main thread
  TFrame_feeder = class(TThread)
  private
    ff_reader: TFFReader;
    ffmpeg_ok: boolean;
    procedure jump(framenum: integer);
    procedure AddToLog(instring: string);
  protected
    procedure Execute; override;
  public
    InFileName: string;
    width, height, fps_num, fps_den: integer;
    interlaced, tff: boolean;
    out_channels: integer;
    max_filled_frames: integer;
    auto_loop: boolean;
    //
    file_is_open: boolean;
    file_duration: int64;
    file_timecode: string;
    initial_point: int64;
    OutputText: TTLtext_list;
    //
    //
    OutputAVFrames: TTL_outAVframes;
    InputAVFrames: TTL_outAVframes;
    //
    commands_list: TTLcommand_list;
    //
    last_jump_position: int64;
    in_point, out_point: int64;
    command_in_progress: boolean;
    //
    deckLinkOutput: IDeckLinkOutput;
  end;

implementation

{ TFrame_feeder }

procedure TFrame_feeder.Execute;
var
  tmp_command_list: TLcommand_list;
  tmp_command: Tcommand;
  //
  tmp_frame_list: TL_outAVframes;
  tmp_frame: ToutAVFrame;
  out_frames: integer;
  out_point_reached: boolean;
  can_wait: boolean;
begin
  ff_reader := TFFReader.Create(OutputText, InFileName, width, height, fps_num,
    fps_den, interlaced, tff, out_channels);

  ff_reader.debug := true;

  file_duration := ff_reader.file_duration;
  file_timecode := ff_reader.TCstring;

  InputAVFrames := TTL_outAVframes.Create;
  ff_reader.OutputAVFrames := InputAVFrames;

  ff_reader.deckLinkOutput := deckLinkOutput;

  if ff_reader.file_is_open then
  begin
    file_is_open := true;
  end
  else
    Exit;

  ffmpeg_ok := true;
  command_in_progress := false;
  last_jump_position := -1;
  in_point := -1;
  out_point := -1;

  while not terminated do
  begin
    // copy frames
    out_point_reached := false;
    tmp_frame_list := InputAVFrames.LockList;
    while tmp_frame_list.Count > 0 do
    begin
      tmp_frame := tmp_frame_list.Items[0];
      tmp_frame_list.Delete(0);

      if not Assigned(tmp_frame) then
        continue;

      if ((out_point > 0) and (tmp_frame.frame_number >= (out_point - 1))) then
        out_point_reached := true;

      if last_jump_position < 0 then
        OutputAVFrames.Add(tmp_frame)
      else
      begin
        if tmp_frame.frame_number < last_jump_position then
        begin
          tmp_frame.Free;
        end
        else
        begin
          OutputAVFrames.Add(tmp_frame);
          last_jump_position := -1;
        end;
      end;
    end;
    InputAVFrames.UnlockList;

    if (out_point_reached or not ffmpeg_ok) and auto_loop then
      jump(in_point);

    tmp_frame_list := OutputAVFrames.LockList;
    out_frames := tmp_frame_list.Count;
    OutputAVFrames.UnlockList;

    // fill frame buffer
    if ffmpeg_ok and (out_frames < max_filled_frames) then
      ffmpeg_ok := ff_reader.read_one_packet;

    // commands processing
    if last_jump_position < 0 then
    begin
      tmp_command := nil;
      tmp_command_list := commands_list.LockList;
      if tmp_command_list.Count > 0 then
      begin
        tmp_command := tmp_command_list.Items[0];
        tmp_command_list.Delete(0);
      end;
      commands_list.UnlockList;

      if Assigned(tmp_command) then
        case tmp_command.code of
          Tcommand_code.jump:
            begin
              // clear output frames
              if tmp_command.out_point > 0 then
              begin
                tmp_frame_list := OutputAVFrames.LockList;
                while tmp_frame_list.Count > 0 do
                begin
                  tmp_frame := tmp_frame_list.Items[0];
                  tmp_frame_list.Delete(0);
                  tmp_frame.Free;
                end;
                OutputAVFrames.UnlockList;
              end;
              jump(tmp_command.in_point);
            end;
          Tcommand_code.auto_jump:
            begin
              in_point := tmp_command.in_point;
              out_point := tmp_command.out_point;
            end;
        end;
    end;

    tmp_frame_list := OutputAVFrames.LockList;
    can_wait := tmp_frame_list.Count > (max_filled_frames - 2);
    OutputAVFrames.UnlockList;

    if can_wait then
      Sleep(5);
  end;

  if file_is_open then
    ff_reader.close_file;

  ff_reader.Free;

  InputAVFrames.Free;
end;

procedure TFrame_feeder.jump(framenum: integer);
begin
  // jump at position - 1sec
  last_jump_position := framenum - (fps_num div fps_den);
  if last_jump_position < 0 then
    last_jump_position := 0;

  ff_reader.jump_at_frame(last_jump_position);
  last_jump_position := framenum;
  ffmpeg_ok := true;
end;

procedure TFrame_feeder.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

end.
