unit ff_reader;

interface

uses
  Winapi.Windows,
  System.AnsiStrings, System.Classes, System.SysUtils, System.Math,
  System.Generics.Defaults, System.Generics.Collections,
  VCL.Forms,
  libavcodec, libavformat, libavutil, libavutil_dict, libavutil_rational,
  libavutil_frame, libavutil_pixfmt, libavutil_samplefmt, libavutil_opt,
  libavutil_hwcontext, libavutil_buffer,
  libswresample, libswscale,
  DeckLinkAPI, DeckLinkAPI.Modes,
  global_types_unit;

type
  TtmpVFrame = class(TOBject)
    VideoFrame: IDeckLinkMutableVideoFrame;
    frame_number: integer;
    destructor Destroy; override;
  end;

  TTL_tmpVframes = TThreadList<TtmpVFrame>;
  TL_tmpVframes = TList<TtmpVFrame>;

  TVframesComparer = class(TComparer<TtmpVFrame>)
  public
    function Compare(const Left, Right: TtmpVFrame): integer; override;
  end;

  TtmpAFrame = class(TOBject)
    AudioData: PData16;
    channel: integer;
    frame_number: integer;
    offset: integer; // offset of first sample from start of frame
    duration: integer;
    destructor Destroy; override;
  end;

  TTL_tmpAframes = TThreadList<TtmpAFrame>;
  TL_tmpAframes = TList<TtmpAFrame>;

  TAframesComparer = class(TComparer<TtmpAFrame>)
  public
    function Compare(const Left, Right: TtmpAFrame): integer; override;
  end;

  TOneStream = class(TOBject)
    constructor Create;
    destructor Destroy; override;
  public
    dec_ctx: PAVCodecContext;
    ts_reached: boolean;
    duration: Int64;
    first_audio_channel: integer;
  end;

  TFFReader = class(TOBject)
    constructor Create(inForLog: TTLtext_list; InFileName: string;
      width, height, fps_num, fps_den: integer; interlaced, tff: boolean;
      out_channels: integer);
    destructor Destroy; override;
  private
    fmt_ctx: PAVFormatContext;
    video_stream_index: integer;
    all_streams: array of TOneStream;
    TCpointer: pAVDictionaryEntry;
    //
    dst_width, dst_height: integer;
    dst_fps: TAVRational;
    dst_interlaced, dst_tff: boolean;
    dst_channels: integer;
    //
    TmpVFramesList: TTL_tmpVframes;
    TmpAFramesList: TTL_tmpAframes;
    //
    l_audio_channels: integer;
    l_file_is_open: boolean;
    l_file_duration: Int64;
    //
    last_rxed_pts: Int64;
    last_jump_position: Int64;
    //
    OutputText: TTLtext_list;
    //
    procedure process_video_frame(in_frame: PAVFrame);
    procedure process_audio_frame(in_frame: PAVFrame; start_channel: integer);
    procedure reassembler;
    //
    procedure flush_tmp_frames;
    //
    function video_frames_buffered_getter: integer;
    function audio_frames_buffered_getter: integer;
    function out_frames_buffered_getter: integer;
    //
    procedure AddToLog(instring: string);
  public
    //
    OutputAVFrames: TTL_outAVframes;
    debug: boolean;
    TCstring: string;
    deckLinkOutput: IDeckLinkOutput;
    //
    property audio_channels: integer read l_audio_channels;
    property file_is_open: boolean read l_file_is_open;
    property file_duration: Int64 read l_file_duration;
    property video_frames_buffered: integer read video_frames_buffered_getter;
    property audio_frames_buffered: integer read audio_frames_buffered_getter;
    property out_frames_buffered: integer read out_frames_buffered_getter;
    //
    function open_file(InFileName: string): boolean;
    function close_file: boolean;
    //
    function read_one_packet: boolean;
    function jump_at_frame(frame_no: Int64): boolean;
    procedure flush_out_frames;
  end;

implementation

uses UnitFFtesting;

function PPtrIdx(P: PPAVStream; i: integer): PAVStream;
begin
  Inc(P, i);
  Result := P^;
end;

function NOD(A, b: integer): integer;
var
  i: integer;
begin
  repeat
    if A > b then
    // Меняем a и b местами, чтобы a было < b
    begin
      i := A;
      A := b;
      b := i;
    end;

    repeat
      b := b - A;
    until (b = 0) Or (b < A);
    Result := A;
  until (b = 0);
end;

{ TOneStream }

constructor TOneStream.Create;
begin
  inherited Create;

  dec_ctx := nil;
end;

destructor TOneStream.Destroy;
begin
  if Assigned(dec_ctx) then
    avcodec_free_context(@dec_ctx);

  inherited Destroy;
end;

{ TFFReader }

constructor TFFReader.Create(inForLog: TTLtext_list; InFileName: string;
  width, height, fps_num, fps_den: integer; interlaced, tff: boolean;
  out_channels: integer);
var
  tmpNOD: integer;
begin
  inherited Create;

  OutputText := inForLog;

  dst_width := width;
  dst_height := height;

  tmpNOD := NOD(fps_num, fps_den);
  dst_fps := av_make_q(fps_num div tmpNOD, fps_den div tmpNOD);

  dst_interlaced := interlaced;
  dst_tff := tff;

  dst_channels := out_channels;

  TCstring := '';

  av_register_all();

  // av_log_set_callback(@avlog);

  // av_log_set_level(AV_LOG_DEBUG);

  last_jump_position := 0;

  l_file_is_open := open_file(InFileName);

  AddToLog('File open: ' + InFileName);

  TmpVFramesList := TTL_tmpVframes.Create;
  TmpAFramesList := TTL_tmpAframes.Create;
end;

destructor TFFReader.Destroy;
begin
  flush_tmp_frames;
  flush_out_frames;
  TmpVFramesList.Free;
  TmpAFramesList.Free;

  if l_file_is_open then
    close_file;

  inherited;
end;

function TFFReader.open_file(InFileName: string): boolean;
var
  stream_ptr: PPAVStream;
  tmp_stream: PAVStream;
  //
  avdec: PAVCodec;
  tmp_dec_ctx: PAVCodecContext;
  //
  opts: PAVDictionary;
  i: integer;
  stream_used: boolean;
begin
  Result := false;

  fmt_ctx := nil;
  l_audio_channels := 0;

  try
    // Init the decoders with reference counting
    opts := nil;
    av_dict_set(@opts, 'refcounted_frames', '1', 0);

    // open input file
    if avformat_open_input(@fmt_ctx, PAnsiChar(AnsiString(InFileName)), nil,
      nil) < 0 then
      raise Exception.Create(Format('Could not open source file %s',
        [InFileName]));

    // get timecode
    TCpointer := av_dict_get(fmt_ctx.metadata, 'timecode', nil, 0);

    // retrieve stream information
    if avformat_find_stream_info(fmt_ctx, nil) < 0 then
      raise Exception.Create('Could not find stream information');

    // get index of main video stream
    video_stream_index := av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1,
      -1, nil, 0);
    if video_stream_index < 0 then
      raise Exception.Create('Could not find video stream in input file');

    // analyzing streams
    SetLength(all_streams, fmt_ctx.nb_streams);
    stream_ptr := fmt_ctx.streams;
    for i := 0 to fmt_ctx.nb_streams - 1 do
    begin
      all_streams[i] := TOneStream.Create;

      // checking for stream content
      tmp_stream := stream_ptr^;

      if not Assigned(TCpointer) then
        TCpointer := av_dict_get(tmp_stream.metadata, 'timecode', nil, 0);

      stream_used := false;
      case tmp_stream.codec.codec_type of
        AVMEDIA_TYPE_VIDEO:
          if i = video_stream_index then
          begin
            stream_used := true;
          end;
        AVMEDIA_TYPE_AUDIO:
          if tmp_stream.codec.sample_rate = 48000 then
          begin
            all_streams[i].first_audio_channel := l_audio_channels;
            Inc(l_audio_channels, tmp_stream.codec.channels);
            stream_used := true;
          end;
      end;

      if stream_used then
      begin
        // find decoder for current stream
        avdec := avcodec_find_decoder(tmp_stream.codecpar.codec_id);

        if not Assigned(avdec) then
          raise Exception.Create('Failed to find codec for stream #' +
            inttostr(i));

        // Allocate a codec context for the decoder
        tmp_dec_ctx := avcodec_alloc_context3(avdec);
        if not Assigned(tmp_dec_ctx) then
          raise Exception.Create
            ('Failed to allocate the codec context for stream #' + inttostr(i));

        // Copy codec parameters from input stream to output codec context
        if avcodec_parameters_to_context(tmp_dec_ctx, tmp_stream.codecpar) < 0
        then
          raise Exception.Create
            ('Failed to copy codec parameters to decoder context for stream #' +
            inttostr(i));

        // open codec
        if avcodec_open2(tmp_dec_ctx, avdec, @opts) < 0 then
          raise Exception.Create('Failed to open codec for stream #' +
            inttostr(i));

        // check parameters of video stream
        if (i = video_stream_index) then
        begin
          if av_cmp_q(tmp_stream.codec.framerate, dst_fps) <> 0 then
            raise Exception.Create
              (Format('Framerate in file %.3f FPS. Must be %.3f FPS',
              [av_q2d(tmp_stream.codec.framerate), av_q2d(dst_fps)]));

          if tmp_stream.codec.width <> dst_width then
            raise Exception.Create(Format('Width in file %d. Must be %d',
              [tmp_stream.codec.width, dst_width]));

          if tmp_stream.codec.height <> dst_height then
            raise Exception.Create(Format('Height in file %d. Must be %d',
              [tmp_stream.codec.height, dst_height]));

          case tmp_stream.codec.field_order of
            AV_FIELD_UNKNOWN:
              AddToLog('! Unknown field order in file');
            AV_FIELD_TT:
              // < Top coded_first, top displayed first
              if not dst_interlaced then
                AddToLog('! File is interlaced (TFF) - video mode progressive !');
            AV_FIELD_BB: // < Bottom coded first, bottom displayed first
              if not dst_interlaced then
                AddToLog('! File is interlaced (BFF) - video mode progressive !');
            AV_FIELD_TB: // < Top coded first, bottom displayed first
              if not dst_interlaced then
                AddToLog('! File is interlaced (TFF) - video mode progressive !');
            AV_FIELD_BT:
              if not dst_interlaced then
                AddToLog('! File is interlaced (BFF) - video mode progressive !');
          end;
          {
            if av_cmp_q(av_inv_q(tmp_stream.codec.time_base), dst_fps) <> 0 then
            raise Exception.Create
            (Format('Timebase in file %.3f FPS. Must be %.3f FPS',
            [av_q2d(av_inv_q(tmp_stream.codec.time_base)), av_q2d(dst_fps)])); }
        end;

        case tmp_stream.codec.codec_type of
          AVMEDIA_TYPE_VIDEO:
            AddToLog(Format('Stream #%d video %s - %d x %d',
              [i, tmp_dec_ctx.codec.name, tmp_stream.codec.width,
              tmp_stream.codec.height]));
          AVMEDIA_TYPE_AUDIO:
            AddToLog(Format('Stream #%d audio %s - %d channels',
              [i, tmp_dec_ctx.codec.name, tmp_stream.codec.channels]));
        end;

        all_streams[i].duration := tmp_stream.duration;

        all_streams[i].dec_ctx := tmp_dec_ctx;
      end
      else
      begin
        all_streams[i].dec_ctx := nil;
      end;

      Inc(stream_ptr);
    end;

    if Assigned(TCpointer) then
      TCstring := TCpointer.value;

    l_file_is_open := true;
    l_file_duration := all_streams[video_stream_index].duration;

    Result := true;
  except
    on E: Exception do
      AddToLog(E.Message);
  end;
end;

function TFFReader.close_file: boolean;
var
  i: integer;
begin
  for i := 0 to Length(all_streams) - 1 do
    if Assigned(all_streams[i]) then
      all_streams[i].Free;

  SetLength(all_streams, 0);

  avformat_close_input(@fmt_ctx);

  l_file_is_open := false;

  Result := true;
end;

function TFFReader.jump_at_frame(frame_no: Int64): boolean;
var
  video_stream: TOneStream;
  i: integer;
begin
  Result := false;

  try
    video_stream := all_streams[video_stream_index];

    if frame_no >= video_stream.duration then
      raise Exception.Create(Format('Frame number (%d) >= video duration (%d)',
        [frame_no, video_stream.duration]));

    // try to search
    flush_tmp_frames();
    if av_seek_frame(fmt_ctx, video_stream_index, frame_no,
      AVSEEK_FLAG_BACKWARD) > 0 then
      raise Exception.Create('av_seek_frame failed');

    for i := 0 to Length(all_streams) - 1 do
      avcodec_flush_buffers(all_streams[i].dec_ctx);

    last_jump_position := frame_no;
    Result := true;
  except
    on E: Exception do
      AddToLog(E.Message);
  end;
end;

function TFFReader.read_one_packet: boolean;
var
  cur_stream: integer;

  pkt: PAVPacket;
  frame: PAVFrame;
  ret_val: integer;
  i: integer;
begin
  Result := false;

  // получаем один пакет из потока
  pkt := av_packet_alloc;
  if av_read_frame(fmt_ctx, pkt) >= 0 then
  begin
    // декодируем пакет в кадр
    cur_stream := pkt.stream_index;
    if Assigned(all_streams[cur_stream].dec_ctx) then
    begin
      // шлём полученный пакет в декодер
      ret_val := avcodec_send_packet(all_streams[cur_stream].dec_ctx, pkt);
      if ret_val < 0 then
        raise Exception.Create('send_packet error');

      // ждём возвращения кадра из декодера и запихиваем его в процессоры
      repeat
        frame := av_frame_alloc();

        ret_val := avcodec_receive_frame
          (all_streams[cur_stream].dec_ctx, frame);

        if ret_val >= 0 then
        begin
          case all_streams[cur_stream].dec_ctx.codec_type of
            AVMEDIA_TYPE_VIDEO:
              if cur_stream = video_stream_index then
              begin
                last_rxed_pts := frame.pts;
                process_video_frame(frame);
              end;
            AVMEDIA_TYPE_AUDIO:
              begin
                process_audio_frame(frame,
                  all_streams[cur_stream].first_audio_channel);
              end;
          end;
        end;
        av_frame_free(@frame);
      until ret_val < 0;
    end;
    av_packet_unref(pkt);
    Result := true;
  end
  else
  begin
    // nothing to read - flash all decoders
    for i := 0 to Length(all_streams) - 1 do
    begin
      if Assigned(all_streams[i].dec_ctx) then
      begin
        // шлём пустой пакет в декодер
        ret_val := avcodec_send_packet(all_streams[i].dec_ctx, nil);
        if ret_val >= 0 then
        begin
          // ждём возвращения кадра из декодера и запихиваем его в процессоры
          repeat
            frame := av_frame_alloc();

            ret_val := avcodec_receive_frame(all_streams[i].dec_ctx, frame);

            if ret_val >= 0 then
            begin
              case all_streams[i].dec_ctx.codec_type of
                AVMEDIA_TYPE_VIDEO:
                  if i = video_stream_index then
                  begin
                    if frame.pts < 0 then
                      frame.pts := last_rxed_pts + 1;
                    process_video_frame(frame);
                  end;
                AVMEDIA_TYPE_AUDIO:
                  begin
                    process_audio_frame(frame,
                      all_streams[i].first_audio_channel);
                  end;
              end;
            end;
            av_frame_free(@frame);
          until ret_val < 0;
        end;
      end;
    end;
  end;

  av_packet_free(@pkt);

  reassembler;
end;

procedure TFFReader.process_video_frame(in_frame: PAVFrame);
var
  // sws
  sws_ctx: PSwsContext;
  tmp_frame: TtmpVFrame;
  out_linesizes: array [0 .. 7] of integer;
  retval: integer;
  i: integer;
  tmp_ptr: Pbyte;
  tmp_dst_pointer: Pointer;
  tmp_dst_pointer_pb: Pbyte;
begin
  if in_frame.pts < last_jump_position then
    Exit;

  try
    // create scaling context
    sws_ctx := sws_getContext(in_frame.width, in_frame.height,
      TAVPixelFormat(in_frame.Format), dst_width, dst_height,
      AV_PIX_FMT_UYVY422, SWS_LANCZOS, nil, nil, nil);

    if not Assigned(sws_ctx) then
      raise Exception.Create('Could not create sws context');

    // new video frame creation
    for i := 0 to 7 do
      out_linesizes[i] := 0;
    out_linesizes[0] := dst_width * 2;

    tmp_frame := TtmpVFrame.Create;

    deckLinkOutput.CreateVideoFrame(dst_width, dst_height, dst_width * 2,
      bmdFormat8BitYUV, bmdFrameFlagDefault, tmp_frame.VideoFrame);

    tmp_frame.VideoFrame.GetBytes(tmp_dst_pointer);
    tmp_dst_pointer_pb := tmp_dst_pointer;

    tmp_frame.frame_number := in_frame.pts;

    // both input and destination are interlaced and input and output have different field order
    if (in_frame.interlaced_frame <> 0) and dst_interlaced and
      ((in_frame.top_field_first <> 0) <> dst_tff) then
    begin
      GetMem(tmp_ptr, out_linesizes[0] * dst_height);
      // scaling
      retval := sws_scale(sws_ctx, @in_frame.data[0], @in_frame.linesize[0], 0,
        in_frame.height, @tmp_ptr, @out_linesizes[0]);
      if retval <> dst_height then
        raise Exception.Create('Scaling failed');

      // copy first line only
      Move(tmp_ptr^, tmp_dst_pointer_pb^, out_linesizes[0]);
      Move(tmp_ptr^, tmp_dst_pointer_pb[out_linesizes[0]],
        out_linesizes[0] * (dst_height - 1));

      FreeMem(tmp_ptr);
    end
    else
    begin
      // scaling

      retval := sws_scale(sws_ctx, @in_frame.data[0], @in_frame.linesize[0], 0,
        in_frame.height, @tmp_dst_pointer_pb, @out_linesizes[0]);
      if retval <> dst_height then
        raise Exception.Create('Scaling failed');
    end;

    TmpVFramesList.Add(tmp_frame);

    sws_freeContext(sws_ctx);
  except
    on E: Exception do
      AddToLog(E.Message);
  end;
end;

procedure TFFReader.process_audio_frame(in_frame: PAVFrame;
  start_channel: integer);
var
  // swr
  swr_ctx: PSwrContext;
  tmp_frame: TtmpAFrame;
  retval: integer;
  i: integer;
  audio_data: array of Pbyte;
  tmp_ptr: Pbyte;
  start_sample, dur_sample, offset: Int64;
  frame_num, frame_start_sample, next_frame_start_sample: Int64;
  cutting_finished: boolean;
  last_frame_num: Int64;
begin
  last_frame_num := ((in_frame.pts + in_frame.nb_samples - 1) * dst_fps.num)
    div (in_frame.sample_rate * dst_fps.den);

  if last_frame_num < last_jump_position then
    Exit;

  try
    swr_ctx := swr_alloc();
    if not Assigned(swr_ctx) then
      raise Exception.Create('Could not allocate resampler context');

    if av_opt_set_int(swr_ctx, PAnsiChar('in_channel_count'), in_frame.channels,
      0) < 0 then
      raise Exception.Create('Could not set in_channel_layout');
    if av_opt_set_int(swr_ctx, PAnsiChar('in_sample_rate'),
      in_frame.sample_rate, 0) < 0 then
      raise Exception.Create('Could not set in_sample_rate');
    if av_opt_set_sample_fmt(swr_ctx, PAnsiChar('in_sample_fmt'),
      TAVSampleFormat(in_frame.Format), 0) < 0 then
      raise Exception.Create('Could not set in_sample_fmt');

    if av_opt_set_int(swr_ctx, 'out_channel_count', in_frame.channels, 0) < 0
    then
      raise Exception.Create('Could not set out_channel_layout');
    if av_opt_set_int(swr_ctx, 'out_sample_rate', in_frame.sample_rate, 0) < 0
    then
      raise Exception.Create('Could not set out_sample_rate');
    if av_opt_set_sample_fmt(swr_ctx, 'out_sample_fmt', AV_SAMPLE_FMT_S16P, 0) < 0
    then
      raise Exception.Create('Could not set out_sample_fmt');

    if swr_init(swr_ctx) < 0 then
      raise Exception.Create('Failed to initialize the resampling context');

    if swr_is_initialized(swr_ctx) <= 0 then
      raise Exception.Create('SWR is not initialized');

    SetLength(audio_data, in_frame.channels);
    for i := 0 to in_frame.channels - 1 do
      GetMem(audio_data[i], in_frame.nb_samples * 2);

    retval := swr_convert(swr_ctx, @audio_data[0], in_frame.nb_samples,
      @in_frame.data[0], in_frame.nb_samples);

    if retval <> in_frame.nb_samples then
      raise Exception.Create('swr_convert error');

    swr_free(@swr_ctx);

    // great, we have data. cutting and sorting
    start_sample := in_frame.pts;
    dur_sample := in_frame.nb_samples;
    offset := 0;
    cutting_finished := false;

    frame_num := (in_frame.pts * dst_fps.num)
      div (in_frame.sample_rate * dst_fps.den);

    repeat
      frame_start_sample := (frame_num * in_frame.sample_rate * dst_fps.den)
        div dst_fps.num;
      next_frame_start_sample := ((frame_num + 1) * in_frame.sample_rate *
        dst_fps.den) div dst_fps.num;

      // input: end point is in the same frame as start point
      if (start_sample + dur_sample) <= next_frame_start_sample then
      begin
        // copy all data to temporary frames
        for i := 0 to Length(audio_data) - 1 do
        begin
          tmp_frame := TtmpAFrame.Create;
          tmp_frame.frame_number := frame_num;
          tmp_frame.offset := start_sample + offset - frame_start_sample;
          tmp_frame.duration := dur_sample - offset;
          tmp_frame.channel := start_channel + i;

          GetMem(tmp_frame.AudioData, tmp_frame.duration * 2);
          tmp_ptr := audio_data[i];
          Inc(tmp_ptr, offset * 2);
          Move(tmp_ptr^, tmp_frame.AudioData^, tmp_frame.duration * 2);
          TmpAFramesList.Add(tmp_frame);
        end;
        cutting_finished := true;
      end
      else
      begin
        // end point is in the next frame. Cut
        for i := 0 to Length(audio_data) - 1 do
        begin
          tmp_frame := TtmpAFrame.Create;
          tmp_frame.frame_number := frame_num;
          tmp_frame.offset := start_sample + offset - frame_start_sample;
          tmp_frame.duration := next_frame_start_sample -
            (start_sample + offset);
          tmp_frame.channel := start_channel + i;

          GetMem(tmp_frame.AudioData, tmp_frame.duration * 2);
          tmp_ptr := audio_data[i];
          Inc(tmp_ptr, offset * 2);
          Move(tmp_ptr^, tmp_frame.AudioData^, tmp_frame.duration * 2);
          TmpAFramesList.Add(tmp_frame);
        end;
        offset := next_frame_start_sample - start_sample;
      end;
      Inc(frame_num);
    until cutting_finished;

  except
    on E: Exception do
      AddToLog(E.Message);
  end;

  swr_free(@swr_ctx);

  if Length(audio_data) > 0 then
    for i := 0 to Length(audio_data) - 1 do
      if Assigned(audio_data[i]) then
        FreeMem(audio_data[i]);
end;

procedure TFFReader.reassembler;
var
  tmp_vlist: TL_tmpVframes;
  tmp_alist: TL_tmpAframes;
  tmp_alist_arr: array of TL_tmpAframes;
  tmpinvframe: TtmpVFrame;
  tmpinaframe: TtmpAFrame;
  v_sort: TVframesComparer;
  a_sort: TAframesComparer;
  cur_frame_number: integer;
  i, iac, iaf, isam: integer;
  frame_start_sample, next_frame_start_sample: Int64;
  part_start_sample: Int64;
  missed, nooneframe: boolean;
  tmp_out_frame: ToutAVFrame;
begin
  v_sort := TVframesComparer.Create;
  a_sort := TAframesComparer.Create;

  SetLength(tmp_alist_arr, l_audio_channels);
  for iac := 0 to l_audio_channels - 1 do
    tmp_alist_arr[iac] := TL_tmpAframes.Create;

  tmp_vlist := TmpVFramesList.LockList;
  tmp_alist := TmpAFramesList.LockList;

  // sort list by frame number
  tmp_vlist.Sort(v_sort);

  repeat
    nooneframe := true;

    for i := 0 to tmp_vlist.Count - 1 do
    begin
      cur_frame_number := tmp_vlist.Items[i].frame_number;

      for iac := 0 to l_audio_channels - 1 do
        tmp_alist_arr[iac].Clear;

      // select audio frames with this frame number and separate it by channel
      for iaf := 0 to tmp_alist.Count - 1 do
        if tmp_alist.Items[iaf].frame_number = cur_frame_number then
          tmp_alist_arr[tmp_alist.Items[iaf].channel].Add(tmp_alist.Items[iaf]);

      frame_start_sample := (cur_frame_number * 48000 * dst_fps.den)
        div dst_fps.num;
      next_frame_start_sample := ((cur_frame_number + 1) * 48000 * dst_fps.den)
        div dst_fps.num;

      missed := false;
      for iac := 0 to l_audio_channels - 1 do
      begin

        if tmp_alist_arr[iac].Count <= 0 then
        begin
          missed := true;
          break;
        end;

        tmp_alist_arr[iac].Sort(a_sort);

        // continuous chain?
        part_start_sample := 0;
        for iaf := 0 to tmp_alist_arr[iac].Count - 1 do
        begin
          tmpinaframe := tmp_alist_arr[iac].Items[iaf];
          if tmpinaframe.offset <> part_start_sample then
          begin
            missed := true;
            break;
          end;

          Inc(part_start_sample, tmpinaframe.duration);
        end;

        // full frame?
        if not missed and
          (part_start_sample <> (next_frame_start_sample - frame_start_sample))
        then
          missed := true;

        if missed then
          break;
      end;

      // assembling
      if not missed then
      begin
        nooneframe := false;
        tmp_out_frame := ToutAVFrame.Create;
        tmp_out_frame.VideoFrame := tmp_vlist.Items[i].VideoFrame;
        tmp_vlist.Items[i].VideoFrame := nil;
        tmp_out_frame.frame_number := tmp_vlist.Items[i].frame_number;
        //
        tmp_out_frame.start_sample := frame_start_sample;
        tmp_out_frame.duration := next_frame_start_sample - frame_start_sample;
        GetMem(tmp_out_frame.AudioData, tmp_out_frame.duration *
          dst_channels * 2);

        for iac := 0 to dst_channels - 1 do
        begin
          if iac < l_audio_channels then
          begin
            // real audio channel
            for iaf := 0 to tmp_alist_arr[iac].Count - 1 do
            begin
              tmpinaframe := tmp_alist_arr[iac].Items[iaf];
              for isam := 0 to tmpinaframe.duration - 1 do
                tmp_out_frame.AudioData
                  [iac + ((tmpinaframe.offset + isam) * dst_channels)] :=
                  tmpinaframe.AudioData[isam];
            end;
          end
          else
          begin
            // empty channels
            for isam := 0 to tmp_out_frame.duration - 1 do
              tmp_out_frame.AudioData[iac + (isam * dst_channels)] := 0;
          end;
        end;
        OutputAVFrames.Add(tmp_out_frame);

        // cleaning
        tmpinvframe := tmp_vlist.Items[i];
        tmpinvframe.Free;
        tmp_vlist.Delete(i);

        for iac := 0 to l_audio_channels - 1 do
          for iaf := 0 to tmp_alist_arr[iac].Count - 1 do
          begin
            tmpinaframe := tmp_alist_arr[iac].Items[iaf];
            tmp_alist.Remove(tmpinaframe);
            tmpinaframe.Free;
          end;
        {
          if debug then
          AddToLog('assembled ' + inttostr(cur_frame_number)); }

        break;
      end;
    end;
  until nooneframe;

  TmpAFramesList.UnlockList;
  TmpVFramesList.UnlockList;

  for iac := 0 to l_audio_channels - 1 do
    tmp_alist_arr[iac].Free;

  v_sort.Free;
  a_sort.Free;
end;

function TFFReader.video_frames_buffered_getter: integer;
var
  tmp_vl: TL_tmpVframes;
begin
  tmp_vl := TmpVFramesList.LockList;
  Result := tmp_vl.Count;
  TmpVFramesList.UnlockList;
end;

function TFFReader.audio_frames_buffered_getter: integer;
var
  tmp_alist: TL_tmpAframes;
begin
  tmp_alist := TmpAFramesList.LockList;

  Result := tmp_alist.Count;
  TmpAFramesList.UnlockList;
end;

function TFFReader.out_frames_buffered_getter: integer;
var
  tmp_avlist: TL_outAVframes;
begin
  tmp_avlist := OutputAVFrames.LockList;

  Result := tmp_avlist.Count;
  OutputAVFrames.UnlockList;
end;

procedure TFFReader.flush_out_frames;
var
  tmpl: TL_outAVframes;
  tmpf: ToutAVFrame;
begin
  tmpl := OutputAVFrames.LockList;
  while tmpl.Count > 0 do
  begin
    tmpf := tmpl.Items[0];
    tmpf.Free;
    tmpl.Delete(0);
  end;
  OutputAVFrames.UnlockList;
end;

procedure TFFReader.flush_tmp_frames;
var
  tmpvl: TL_tmpVframes;
  tmpvf: TtmpVFrame;
  tmpal: TL_tmpAframes;
  tmpaf: TtmpAFrame;
  cntr: integer;
begin
  tmpvl := TmpVFramesList.LockList;
  while tmpvl.Count > 0 do
  begin
    tmpvf := tmpvl.Items[0];
    cntr := tmpvf.VideoFrame._Release;
    tmpvf.Free;
    tmpvl.Delete(0);
  end;
  TmpVFramesList.UnlockList;

  tmpal := TmpAFramesList.LockList;
  while tmpal.Count > 0 do
  begin
    tmpaf := tmpal.Items[0];
    tmpaf.Free;
    tmpal.Delete(0);
  end;
  TmpAFramesList.UnlockList;
end;

procedure TFFReader.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

{ TtmpVFrame }

destructor TtmpVFrame.Destroy;
begin
  if Assigned(VideoFrame) then
    VideoFrame._Release;

  inherited;
end;

{ TtmpAFrame }

destructor TtmpAFrame.Destroy;
begin
  if Assigned(AudioData) then
    FreeMem(AudioData);

  inherited;
end;

{ TVframesComparer }

function TVframesComparer.Compare(const Left, Right: TtmpVFrame): integer;
begin
  Result := CompareValue(TtmpVFrame(Left).frame_number,
    TtmpVFrame(Right).frame_number);
end;

{ TAframesComparer }

function TAframesComparer.Compare(const Left, Right: TtmpAFrame): integer;
var
  tmp_r: integer;
begin
  tmp_r := CompareValue(TtmpAFrame(Left).frame_number,
    TtmpAFrame(Right).frame_number);
  if tmp_r = 0 then
  begin
    tmp_r := CompareValue(TtmpAFrame(Left).offset, TtmpAFrame(Right).offset);
  end;
  Result := tmp_r;
end;

end.
