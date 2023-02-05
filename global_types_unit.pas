unit global_types_unit;

interface

uses
  System.Generics.Defaults, System.Generics.Collections, System.SysUtils,
  System.Math,
  Winapi.Messages,
  DeckLinkAPI;

const
  MyLogMessage = WM_USER + 1;

type
  TData16 = array [0 .. 16383] of smallint;
  PData16 = ^TData16;

  ToutAVFrame = class(TOBject)
    VideoFrame: IDeckLinkMutableVideoFrame;
    AudioData: PData16;
    frame_number: integer;
    start_sample: integer;
    duration: integer;
    constructor Create; overload;
    destructor Destroy; override;
  end;

  TTL_outAVframes = TThreadList<ToutAVFrame>;
  TL_outAVframes = TList<ToutAVFrame>;

  TOne_text = class(TOBject)
  private
    l_string: string;
  public
    property text: string read l_string;
    Constructor Create(intext: string); overload;
  end;

  TTLtext_list = TThreadList<TOne_text>;
  TLtext_list = TList<TOne_text>;

implementation

{ TOne_text }

constructor TOne_text.Create(intext: string);
begin
  inherited Create;

  l_string := FormatDateTime('yyyy-mm-dd hh:nn:ss:zzz', Now()) + ' ' + intext;
end;

{ TtmpAVFrame }

constructor ToutAVFrame.Create;
begin
  inherited Create;

  VideoFrame := nil;
  AudioData := nil;
  frame_number := -1;
  start_sample := -1;
  duration := -1;
end;

destructor ToutAVFrame.Destroy;
var
  tmpctr: integer;
begin
  // if Assigned(VideoFrame) then
  // VideoFrame._Release;
  // tmpctr := VideoFrame._AddRef;
  if Assigned(AudioData) then
    FreeMem(AudioData);

  inherited;
end;

end.
