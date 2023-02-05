object FormBMFFplayer: TFormBMFFplayer
  Left = 0
  Top = 0
  Caption = 'i'
  ClientHeight = 595
  ClientWidth = 859
  Color = clBtnFace
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  OnClose = FormClose
  OnCreate = FormCreate
  OnResize = FormResize
  PixelsPerInch = 96
  TextHeight = 13
  object LabelO: TLabel
    Left = 336
    Top = 235
    Width = 33
    Height = 13
    Alignment = taCenter
    Caption = 'LabelO'
  end
  object LabelFileName: TLabel
    Left = 378
    Top = 16
    Width = 135
    Height = 25
    Caption = 'LabelFileName'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -21
    Font.Name = 'Tahoma'
    Font.Style = []
    ParentFont = False
  end
  object Memo1: TMemo
    Left = 8
    Top = 266
    Width = 833
    Height = 311
    Lines.Strings = (
      'Memo1')
    ScrollBars = ssVertical
    TabOrder = 0
  end
  object PanelPreview: TPanel
    Left = 8
    Top = 8
    Width = 320
    Height = 240
    Caption = 'PanelPreview'
    TabOrder = 1
  end
  object ProgressBarBuffer: TProgressBar
    Left = 342
    Top = 8
    Width = 19
    Height = 217
    Orientation = pbVertical
    BarColor = clGreen
    TabOrder = 2
  end
  object PanelPositions: TPanel
    Left = 375
    Top = 137
    Width = 466
    Height = 111
    TabOrder = 3
    object PanelTCin: TPanel
      Left = 9
      Top = 63
      Width = 129
      Height = 33
      Caption = '00:00:00:00'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Arial'
      Font.Pitch = fpFixed
      Font.Style = []
      ParentFont = False
      TabOrder = 0
    end
    object TrackBarPosition: TTrackBar
      Left = 9
      Top = 12
      Width = 440
      Height = 45
      PageSize = 25
      TabOrder = 1
      TabStop = False
      TickMarks = tmTopLeft
    end
    object PanelTCposition: TPanel
      Left = 162
      Top = 63
      Width = 129
      Height = 33
      Caption = '00:00:00:00'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Arial'
      Font.Pitch = fpFixed
      Font.Style = []
      ParentFont = False
      TabOrder = 2
    end
    object PanelTCout: TPanel
      Left = 321
      Top = 63
      Width = 129
      Height = 33
      Caption = '00:00:00:00'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Arial'
      Font.Pitch = fpFixed
      Font.Style = []
      ParentFont = False
      TabOrder = 3
    end
  end
  object PanelChase: TPanel
    Left = 375
    Top = 47
    Width = 466
    Height = 84
    TabOrder = 4
    object LabelIncomingTC: TLabel
      Left = 14
      Top = 12
      Width = 59
      Height = 13
      Caption = 'Incoming TC'
    end
    object LabelDifference: TLabel
      Left = 149
      Top = 12
      Width = 85
      Height = 13
      Caption = 'Difference (in ms)'
    end
    object LabelPS: TLabel
      Left = 288
      Top = 12
      Width = 3
      Height = 13
    end
    object LabelCS: TLabel
      Left = 288
      Top = 31
      Width = 3
      Height = 13
    end
    object PanelIncomingTC: TPanel
      Left = 8
      Top = 31
      Width = 129
      Height = 33
      Caption = '00:00:00:00'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Arial'
      Font.Pitch = fpFixed
      Font.Style = []
      ParentFont = False
      TabOrder = 0
    end
    object PanelDifference: TPanel
      Left = 143
      Top = 31
      Width = 129
      Height = 33
      Caption = '0'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -21
      Font.Name = 'Arial'
      Font.Pitch = fpFixed
      Font.Style = []
      ParentFont = False
      TabOrder = 1
    end
  end
  object Timer1: TTimer
    Interval = 10
    OnTimer = Timer1Timer
    Left = 816
    Top = 248
  end
end
