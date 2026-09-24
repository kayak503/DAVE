using W = System.Windows;
using C = System.Windows.Controls;
using M = System.Windows.Media;
using Input = System.Windows.Input;
using System.Text.RegularExpressions;

namespace LocalVoice;

public sealed partial class MainForm
{
 WpfPresentation? presentation;
 List<GpuDevice> availableGpus=new();
 NotifyIcon? tray;bool quitting;
 void InstallPresentation()
 {
  presentation=new WpfPresentation(this);FormClosing+=(_,_)=>presentation.CancelVoicePreview();
  var host=new System.Windows.Forms.Integration.ElementHost{Dock=DockStyle.Fill,Child=presentation};
  Controls.Add(host);host.BringToFront();tabs.Visible=false;
  // Keep the existing operation controls as the controller until those services are extracted.
  // They retain their operation events; the hidden legacy surface is excluded from input and accessibility.
  notice.Dock=DockStyle.None;notice.Size=Size.Empty;
  using var icon=typeof(MainForm).Assembly.GetManifestResourceStream("LocalVoice.DAVE.ico");
  if(icon!=null)Icon=new Icon(icon);
  if(servicesEnabled){
   var menu=new ContextMenuStrip();
   void Add(string label,Action action)=>menu.Items.Add(label,null,(_,_)=>action());
   void ShowMain(){Show();WindowState=FormWindowState.Normal;Activate();}
   Add("Show DAVE",ShowMain);menu.Items.Add(new ToolStripSeparator());Add("Start / finish dictation",()=>_ =Safe(()=>ToggleDictation()));Add("Read selected text",()=>_ =Safe(ReadSelection));Add("Stop reading",StopReading);menu.Items.Add(new ToolStripSeparator());Add("Settings",()=>{ShowMain();presentation.ShowSettings();});Add("Quit DAVE",()=>{quitting=true;Close();});
   tray=new NotifyIcon{Text="DAVE — Everything on your device",Icon=Icon,ContextMenuStrip=menu,Visible=true};tray.DoubleClick+=(_,_)=>ShowMain();FormClosed+=(_,_)=>{tray.Visible=false;tray.Dispose();menu.Dispose();};
  }
 }
 protected override void OnFormClosing(FormClosingEventArgs e){if(servicesEnabled&&tray!=null&&!quitting&&e.CloseReason==CloseReason.UserClosing){e.Cancel=true;Hide();return;}quitting=true;base.OnFormClosing(e);}
 void RenderPresentation(string path)
 {
  presentation!.RefreshState();presentation.UpdateLayout();
  presentation.Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.Render);
  var bitmap=new M.Imaging.RenderTargetBitmap((int)Math.Ceiling(presentation.ActualWidth),(int)Math.Ceiling(presentation.ActualHeight),96,96,M.PixelFormats.Pbgra32);
  bitmap.Render(presentation);var encoder=new M.Imaging.PngBitmapEncoder();encoder.Frames.Add(M.Imaging.BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);
 }

 // Layout and control order mirror macos/Sources/Views.swift and TranscriptionView.swift.
 // All measurements here are device-independent pixels, scaled once by WPF.
 internal sealed class WpfPresentation:C.UserControl
 {
  readonly MainForm owner;
  readonly C.Grid root=new(),detail=new();readonly C.ContentControl page=new();
  readonly C.TextBlock title=Text("Read",16,true),toastText=Text("",13),wordCount=Text("0 words",12),readStatus=Text("Ready",12);
  readonly C.Border toast=new(){CornerRadius=new W.CornerRadius(10),Padding=new W.Thickness(14),Margin=new W.Thickness(20,8,20,0),VerticalAlignment=W.VerticalAlignment.Top,MaxWidth=620};
  readonly List<C.Button> navigation=new();readonly C.StackPanel toolbar=Horizontal(),readerLines=new(),modelRows=new(),voiceRows=new();
  readonly C.TextBox sourceEditor=new(){AcceptsReturn=true,AcceptsTab=true,TextWrapping=W.TextWrapping.Wrap,VerticalScrollBarVisibility=C.ScrollBarVisibility.Auto,FontFamily=new M.FontFamily("Consolas"),FontSize=14,BorderThickness=new W.Thickness(0),Padding=new W.Thickness(24)};
  readonly C.TextBox transcriptEditor=new(){AcceptsReturn=true,TextWrapping=W.TextWrapping.Wrap,VerticalScrollBarVisibility=C.ScrollBarVisibility.Auto,FontSize=17};
  readonly C.ContentControl readerBody=new();readonly C.Grid reader=new(),dictation=new(),transcription=new();
  readonly C.Border readerFooter=new(),generationPanel=new();readonly C.TextBlock generationText=Text("",12);
  readonly C.StackPanel emptyReader=new(){HorizontalAlignment=W.HorizontalAlignment.Center,VerticalAlignment=W.VerticalAlignment.Center};
  readonly C.Button readMode,editMode,play,stop,speed,previous,next,record,cancelRecording,transcribe,listen,copyDictation,readBack,suggest,export,undo;
  readonly C.TextBlock dictationTitle=Text("Speak naturally",21),dictationHint=Text("Your voice stays on this PC.",13),audioTitle=Text("Transcribe audio",14,true),audioHint=Text("Audio stays on this PC",12),transcriptionStatus=Text("Open an audio file to begin.",12),hardwareSummary=Text("Detecting available acceleration…",12);
  readonly C.StackPanel captionRows=new(),speakerOptions=new();readonly C.ScrollViewer readerScroll;
  readonly C.ProgressBar transcriptionProgress=new(){Height=3,Minimum=0,Maximum=1000};
  readonly C.Canvas waveform=new(){Height=45,ClipToBounds=true};readonly Queue<float> levels=new();
  readonly List<(C.ComboBox View,ComboBox Source)> comboBindings=new();
  readonly List<(C.Button View,Button Source)> buttonBindings=new();
  readonly List<C.Button> sentenceButtons=new();readonly List<C.Button> modelActions=new();
  readonly Dictionary<string,ModernButton> oldActions=new();
  W.Window? settingsWindow;C.ScrollViewer? settingsScroll;
  C.Button? readShortcutView,dictationShortcutView;
  C.CheckBox? separateView;C.ComboBox? peopleView;
  string renderedSource="",renderedModels="",renderedCaptions="",renderedVoices="";bool editing,syncingView;int selectedPage=-1,lastSentence=-2;bool lastReadCode;
  static M.Brush Brush(string color)=>new M.SolidColorBrush((M.Color)M.ColorConverter.ConvertFromString(color));
  static readonly M.Brush Secondary=Brush("#727276"),Accent=Brush("#007AFF"),Line=Brush("#DFDFE2");
  static C.TextBlock Text(string text,double size=13,bool bold=false)=>new(){Text=text,FontSize=size,FontWeight=bold?W.FontWeights.SemiBold:W.FontWeights.Normal,TextWrapping=W.TextWrapping.Wrap};
  static C.StackPanel Horizontal()=>new(){Orientation=C.Orientation.Horizontal,VerticalAlignment=W.VerticalAlignment.Center};
  static void Gap(C.Panel p,int width=8)=>p.Children.Add(new C.Border{Width=width});
  static C.Border Divider()=>new(){Height=1,Background=Line};
  C.Button Button(string label,Action action,string? icon=null,string? style=null)
  {
   var button=new C.Button{Content=label,Style=(W.Style)FindResource((object?)style??typeof(C.Button)),ToolTip=label};
   W.Automation.AutomationProperties.SetName(button,label);
   if(icon!=null){var content=Horizontal();content.Children.Add(Symbol(icon));if(label.Length>0){Gap(content,6);content.Children.Add(Text(label));}button.Content=content;}
   button.Click+=(_,_)=>{action();RefreshState();};return button;
  }
  C.Button IconButton(string label,string icon,Action action){var button=Button("",action,icon,"Plain");button.ToolTip=label;W.Automation.AutomationProperties.SetName(button,label);return button;}
  void Invoke(Button button){if(button.Enabled&&button is ModernButton modern)modern.InvokeAction();}
  void Invoke(string label){if(oldActions.TryGetValue(label,out var action))Invoke(action);}
  static IEnumerable<Control> Descendants(Control parent){foreach(Control child in parent.Controls){yield return child;foreach(var nested in Descendants(child))yield return nested;}}

  public WpfPresentation(MainForm owner)
  {
   this.owner=owner;Resources.MergedDictionaries.Add(new W.ResourceDictionary{Source=new Uri("/DAVE;component/MacAppearance.xaml",UriKind.Relative)});
   FontFamily=new M.FontFamily("Segoe UI");FontSize=13;Foreground=Brush("#242426");Background=M.Brushes.White;
   UseLayoutRounding=true;SnapsToDevicePixels=true;
   foreach(var button in Descendants(owner.tabs).OfType<ModernButton>())oldActions.TryAdd(button.Text,button);
   root.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new W.GridLength(175)});root.ColumnDefinitions.Add(new C.ColumnDefinition());
   var sidebar=new C.DockPanel{Background=Brush("#F0F0F2"),LastChildFill=true};
   var settings=Button("Settings",OpenSettings,"gearshape","Navigation");settings.Margin=new W.Thickness(10,8,10,12);C.DockPanel.SetDock(settings,C.Dock.Bottom);sidebar.Children.Add(settings);
   var nav=new C.StackPanel{Margin=new W.Thickness(10,20,10,0)};var brand=Text("DAVE",20,true);brand.Margin=new W.Thickness(10,0,0,3);nav.Children.Add(brand);var tagline=Text("Everything on your device.",11);tagline.Foreground=Secondary;tagline.Margin=new W.Thickness(10,0,0,22);nav.Children.Add(tagline);
   string[] names={"Read","Dictate","Transcribe","Models"},icons={"book.closed","mic","waveform.badge.magnifyingglass","cpu"};
   for(int i=0;i<names.Length;i++){int index=i;var button=Button(names[i],()=>owner.tabs.SelectedIndex=index,icons[i],"Navigation");navigation.Add(button);nav.Children.Add(button);}
   sidebar.Children.Add(nav);root.Children.Add(new C.Border{Child=sidebar,BorderBrush=Line,BorderThickness=new W.Thickness(0,0,1,0)});
   C.Grid.SetColumn(detail,1);detail.RowDefinitions.Add(new C.RowDefinition{Height=new W.GridLength(54)});detail.RowDefinitions.Add(new C.RowDefinition());
   var header=new C.DockPanel{LastChildFill=true,Margin=new W.Thickness(20,0,16,0)};C.DockPanel.SetDock(toolbar,C.Dock.Right);header.Children.Add(toolbar);title.VerticalAlignment=W.VerticalAlignment.Center;header.Children.Add(title);
   detail.Children.Add(new C.Border{Child=header,Background=Brush("#FAFAFB"),BorderBrush=Line,BorderThickness=new W.Thickness(0,0,0,1)});C.Grid.SetRow(page,1);detail.Children.Add(page);root.Children.Add(detail);Content=root;
   var toastContent=new C.DockPanel();var dismiss=IconButton("Dismiss notification","xmark",()=>{owner.noticeUntil=DateTime.MinValue;owner.notice.Text="";});C.DockPanel.SetDock(dismiss,C.Dock.Right);toastContent.Children.Add(dismiss);toastContent.Children.Add(toastText);toast.Child=toastContent;toast.Background=Brush("#F7F7FA");toast.BorderBrush=Line;toast.BorderThickness=new W.Thickness(1);toast.Effect=new M.Effects.DropShadowEffect{BlurRadius=16,Opacity=.12,ShadowDepth=3};C.Grid.SetColumn(toast,1);C.Grid.SetRowSpan(toast,2);C.Panel.SetZIndex(toast,20);root.Children.Add(toast);toast.Visibility=W.Visibility.Collapsed;
   toast.MouseEnter+=(_,_)=>owner.hoverNotice=true;toast.MouseLeave+=(_,_)=>{owner.hoverNotice=false;owner.noticeUntil=DateTime.UtcNow.AddSeconds(4);};
   play=Button("Read",()=>Invoke(owner.playButton),"play.fill","Plain");stop=IconButton("Stop reading","stop.fill",()=>InvokeStop());
   readMode=Button("Read",()=>owner.ShowSentences());editMode=Button("Edit",()=>owner.ShowEditor());
   speed=Button("Speed 1×",()=>Invoke(owner.speedButton));previous=IconButton("Previous sentence (Left arrow)","backward.end.fill",()=>Skip(-1));next=IconButton("Next sentence (Right arrow)","forward.end.fill",()=>Skip(1));
   record=IconButton("Start dictation","mic.fill",()=>Invoke(owner.recordButton));record.Style=(W.Style)FindResource("Record");record.Width=record.Height=54;
   cancelRecording=Button("Cancel",()=>_ =owner.Safe(owner.CancelDictation));copyDictation=Button("Copy",()=>owner.Copy(owner.dictated.Text));readBack=Button("Read Back",()=>Invoke("Read back"));suggest=Button("Suggest Wording",()=>_ =owner.Safe(owner.SuggestWording));
   transcribe=Button("Transcribe",()=>Invoke(owner.transcribeButton),style:"Primary");listen=Button("Listen",()=>Invoke("Listen / pause"));export=Button("Export…",owner.ExportTranscript);undo=Button("Undo",()=>{owner.transcript.Undo();owner.RefreshCaptions();});
   readerScroll=new C.ScrollViewer{Content=readerLines,Background=M.Brushes.White};readerLines.MaxWidth=816;readerLines.Margin=new W.Thickness(28);readerLines.HorizontalAlignment=W.HorizontalAlignment.Stretch;
   BuildReader();BuildDictation();BuildTranscription();
   owner.recorder.Level+=value=>{Dispatcher.BeginInvoke(()=>{levels.Enqueue(value);while(levels.Count>100)levels.Dequeue();DrawWaveform();});};
   owner.FormClosed+=(_,_)=>{StopPreview();settingsWindow?.Close();};
   owner.Shown+=(_,_)=>{double scale=owner.DeviceDpi/96d;owner.MinimumSize=new Size((int)(760*scale)+16,(int)(520*scale)+40);};
   PreviewKeyDown+=(_,e)=>{
    if(e.Key==Input.Key.O&&Input.Keyboard.Modifiers==Input.ModifierKeys.Control){Invoke(selectedPage==2?"Open audio":"Open document");e.Handled=true;}
    else if(e.Key==Input.Key.V&&Input.Keyboard.Modifiers==(Input.ModifierKeys.Control|Input.ModifierKeys.Shift)){owner.tabs.SelectedIndex=0;Paste();e.Handled=true;}
    else if(selectedPage==0&&!editing&&e.Key is Input.Key.Left or Input.Key.Right){Skip(e.Key==Input.Key.Left?-1:1);e.Handled=true;}
   };
   RefreshState();
  }

  void BuildReader()
  {
   reader.RowDefinitions.Add(new C.RowDefinition{Height=new W.GridLength(49)});reader.RowDefinitions.Add(new C.RowDefinition());reader.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});reader.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});
   var modes=Horizontal();foreach(var button in new[]{readMode,editMode}){button.Width=70;button.Padding=new W.Thickness(8,3,8,3);button.MinHeight=25;modes.Children.Add(button);}var modeBar=new C.DockPanel{Margin=new W.Thickness(24,10,24,10)};C.DockPanel.SetDock(wordCount,C.Dock.Right);wordCount.VerticalAlignment=W.VerticalAlignment.Center;wordCount.Foreground=Secondary;modeBar.Children.Add(wordCount);modeBar.Children.Add(modes);reader.Children.Add(new C.Border{Child=modeBar,BorderBrush=Line,BorderThickness=new W.Thickness(0,0,0,1)});
   var emptyIcon=Symbol("text.book.closed",44);emptyIcon.HorizontalAlignment=W.HorizontalAlignment.Center;emptyIcon.Margin=new W.Thickness(0,0,0,18);emptyReader.Children.Add(emptyIcon);
   var heading=Text("Ready when you are",22);heading.TextAlignment=W.TextAlignment.Center;emptyReader.Children.Add(heading);
   var hint=Text("Paste a passage or open a text or Markdown file.\nYour words stay on this PC.",13);hint.Foreground=Secondary;hint.TextAlignment=W.TextAlignment.Center;hint.Margin=new W.Thickness(0,14,0,18);emptyReader.Children.Add(hint);
   var actions=Horizontal();actions.HorizontalAlignment=W.HorizontalAlignment.Center;actions.Children.Add(Button("Paste Text",Paste,style:"Primary"));Gap(actions);actions.Children.Add(Button("Open File…",()=>Invoke("Open document")));Gap(actions);actions.Children.Add(Button("Write Text",()=>owner.ShowEditor()));emptyReader.Children.Add(actions);
   var shortcut=Text($"Or select text in another app and press {Native.ShortcutName(owner.prefs.ReadModifiers,owner.prefs.ReadKey)}.",11);shortcut.Foreground=Secondary;shortcut.TextAlignment=W.TextAlignment.Center;shortcut.Margin=new W.Thickness(20,20,20,0);emptyReader.Children.Add(shortcut);
   C.Grid.SetRow(readerBody,1);reader.Children.Add(readerBody);
   generationText.Foreground=Secondary;generationPanel.Child=generationText;generationPanel.Padding=new W.Thickness(18,9,18,9);generationPanel.Background=Brush("#F7F7F8");generationPanel.BorderBrush=Line;generationPanel.BorderThickness=new W.Thickness(0,1,0,0);C.Grid.SetRow(generationPanel,2);reader.Children.Add(generationPanel);
   var footer=new C.DockPanel{Margin=new W.Thickness(16,10,16,10)};var controls=Horizontal();controls.Children.Add(previous);controls.Children.Add(next);Gap(controls,12);controls.Children.Add(speed);C.DockPanel.SetDock(controls,C.Dock.Right);footer.Children.Add(controls);var icon=Symbol("speaker.wave.2");icon.Margin=new W.Thickness(0,0,10,0);C.DockPanel.SetDock(icon,C.Dock.Left);footer.Children.Add(icon);readStatus.VerticalAlignment=W.VerticalAlignment.Center;readStatus.TextTrimming=W.TextTrimming.CharacterEllipsis;readStatus.TextWrapping=W.TextWrapping.NoWrap;footer.Children.Add(readStatus);
   readerFooter.Child=footer;readerFooter.Background=Brush("#F7F7F8");readerFooter.BorderBrush=Line;readerFooter.BorderThickness=new W.Thickness(0,1,0,0);C.Grid.SetRow(readerFooter,3);reader.Children.Add(readerFooter);
   sourceEditor.TextChanged+=(_,_)=>{if(!syncingView)owner.editor.Text=sourceEditor.Text;};
  }
  void BuildDictation()
  {
   dictation.Margin=new W.Thickness(30);dictation.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});dictation.RowDefinitions.Add(new C.RowDefinition{Height=new W.GridLength(75)});dictation.RowDefinitions.Add(new C.RowDefinition());dictation.RowDefinitions.Add(new C.RowDefinition{Height=new W.GridLength(50)});
   var header=new C.DockPanel();C.DockPanel.SetDock(cancelRecording,C.Dock.Right);header.Children.Add(cancelRecording);record.Margin=new W.Thickness(0,0,20,0);C.DockPanel.SetDock(record,C.Dock.Left);header.Children.Add(record);var words=new C.StackPanel{VerticalAlignment=W.VerticalAlignment.Center};words.Children.Add(dictationTitle);dictationHint.Foreground=Secondary;dictationHint.Margin=new W.Thickness(0,5,0,0);words.Children.Add(dictationHint);header.Children.Add(words);dictation.Children.Add(header);
   C.Grid.SetRow(waveform,1);dictation.Children.Add(waveform);waveform.SizeChanged+=(_,_)=>DrawWaveform();
   var transcriptCard=new C.Border{CornerRadius=new W.CornerRadius(10),BorderBrush=Line,BorderThickness=new W.Thickness(1),Background=M.Brushes.White,Padding=new W.Thickness(8),Child=transcriptEditor};transcriptEditor.BorderThickness=new W.Thickness(0);C.Grid.SetRow(transcriptCard,2);dictation.Children.Add(transcriptCard);
   var actions=new C.DockPanel{Margin=new W.Thickness(0,15,0,0)};C.DockPanel.SetDock(suggest,C.Dock.Right);actions.Children.Add(suggest);var left=Horizontal();left.Children.Add(copyDictation);Gap(left);left.Children.Add(readBack);actions.Children.Add(left);C.Grid.SetRow(actions,3);dictation.Children.Add(actions);
   transcriptEditor.TextChanged+=(_,_)=>{if(!syncingView)owner.dictated.Text=transcriptEditor.Text;};
  }
  void BuildTranscription()
  {
   transcription.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});transcription.RowDefinitions.Add(new C.RowDefinition());transcription.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});
   var setup=new C.StackPanel();var heading=new C.DockPanel{Margin=new W.Thickness(20)};var open=Button("Open Audio…",()=>Invoke("Open audio"));C.DockPanel.SetDock(open,C.Dock.Right);heading.Children.Add(open);var icon=Symbol("waveform.badge.magnifyingglass",28);icon.Margin=new W.Thickness(0,0,12,0);C.DockPanel.SetDock(icon,C.Dock.Left);heading.Children.Add(icon);var name=new C.StackPanel();name.Children.Add(audioTitle);audioHint.Foreground=Secondary;audioHint.Margin=new W.Thickness(0,3,0,0);name.Children.Add(audioHint);heading.Children.Add(name);setup.Children.Add(heading);setup.Children.Add(Divider());
   var options=new C.StackPanel{Margin=new W.Thickness(20,14,20,14)};options.Children.Add(Field("Transcription model",BindCombo(owner.transcriptionModel)));
   var guidance=Text("Whisper Small or above is recommended for conversations. Speaker identification is a separate model.",12);guidance.Foreground=Secondary;guidance.Margin=new W.Thickness(0,0,0,7);options.Children.Add(guidance);
   separateView=new C.CheckBox{Content="Distinguish speakers",IsChecked=owner.separate.Checked};separateView.Checked+=(_,_)=>owner.separate.Checked=true;separateView.Unchecked+=(_,_)=>owner.separate.Checked=false;options.Children.Add(separateView);
   peopleView=new C.ComboBox{ItemsSource=Enumerable.Range(0,21).Select(i=>i==0?"Automatic":$"{i} people (maximum)").ToArray(),SelectedIndex=owner.prefs.ExpectedSpeakers};peopleView.SelectionChanged+=(_,_)=>{if(!syncingView&&peopleView.SelectedIndex>=0)owner.speakerCount.Value=peopleView.SelectedIndex;};speakerOptions.Children.Add(Field("Voices",peopleView));speakerOptions.Children.Add(Field("Speaker identification",BindCombo(owner.speakerChoice)));var download=Button("Download Speaker Model",()=>Invoke(owner.downloadSpeakers));buttonBindings.Add((download,owner.downloadSpeakers));speakerOptions.Children.Add(download);options.Children.Add(speakerOptions);setup.Children.Add(options);setup.Children.Add(Divider());transcription.Children.Add(setup);
   var scroll=new C.ScrollViewer{Content=captionRows};C.Grid.SetRow(scroll,1);transcription.Children.Add(scroll);
   var bottom=new C.StackPanel();bottom.Children.Add(transcriptionProgress);transcriptionStatus.Margin=new W.Thickness(20,10,20,0);transcriptionStatus.Foreground=Secondary;bottom.Children.Add(transcriptionStatus);var actions=new C.DockPanel{Margin=new W.Thickness(20,10,20,16)};var right=Horizontal();right.Children.Add(undo);Gap(right);right.Children.Add(Button("Copy",()=>owner.Copy(owner.transcript.Export("txt"))));Gap(right);right.Children.Add(export);C.DockPanel.SetDock(right,C.Dock.Right);actions.Children.Add(right);var left=Horizontal();left.Children.Add(transcribe);Gap(left);left.Children.Add(listen);actions.Children.Add(left);bottom.Children.Add(actions);C.Grid.SetRow(bottom,2);transcription.Children.Add(bottom);
  }

  void Paste(){if(Clipboard.ContainsText()){owner.editor.Text=Clipboard.GetText();owner.ShowSentences();}}
  void InvokeStop(){owner.StopReading();RefreshState();}
  void Skip(int delta){if(owner.sentences.Items.Count==0)return;_ =owner.Safe(()=>owner.StartReading(Math.Clamp(owner.readingIndex+delta,0,owner.sentences.Items.Count-1)));}
  public void SetEditing(bool value){editing=value;UpdateReader();if(value)Dispatcher.BeginInvoke(()=>sourceEditor.Focus());}
  void UpdateReader()
  {
   bool changed=renderedSource!=owner.editor.Text||lastReadCode!=owner.prefs.ReadCode;
   if(changed){if(owner.readingCancel==null)owner.readingIndex=0;renderedSource=owner.editor.Text;lastReadCode=owner.prefs.ReadCode;RenderDocument();}
   if(sourceEditor.Text!=owner.editor.Text){syncingView=true;sourceEditor.Text=owner.editor.Text;syncingView=false;}
   readerBody.Content=editing?sourceEditor:string.IsNullOrWhiteSpace(owner.editor.Text)?emptyReader:readerScroll;
   readMode.Background=editing?Brush("#EAEAEC"):M.Brushes.White;editMode.Background=editing?M.Brushes.White:Brush("#EAEAEC");
   wordCount.Text=$"{Regex.Matches(owner.editor.Text,@"\S+").Count} words";
   readerFooter.Visibility=owner.editor.Text.Length>0?W.Visibility.Visible:W.Visibility.Collapsed;
  }
  void RenderDocument()
  {
   readerLines.Children.Clear();sentenceButtons.Clear();bool code=false;int index=0;
   foreach(var line in owner.editor.Text.Replace("\r","").Split('\n')){
    if(line.TrimStart().StartsWith("```")){code=!code;continue;}if(string.IsNullOrWhiteSpace(line)){readerLines.Children.Add(new C.Border{Height=10});continue;}
    bool heading=!code&&Regex.IsMatch(line,@"^\s{0,3}#{1,6}\s");
    var passages=code?Enumerable.Range(0,(line.Length+1199)/1200).Select(i=>line.Substring(i*1200,Math.Min(1200,line.Length-i*1200))):ReadDocument.Sentences(line);
    foreach(var passage in passages){
     var text=Text(passage,heading?22:code?13:18,heading);text.LineHeight=heading?30:27;if(code)text.FontFamily=new M.FontFamily("Consolas");
     if(!code){var emphasized=Regex.Matches(line,@"\*\*(.+?)\*\*|__(.+?)__");int at=0;foreach(Match match in emphasized){string word=match.Groups[1].Success?match.Groups[1].Value:match.Groups[2].Value;int pos=passage.IndexOf(word,at,StringComparison.Ordinal);if(pos<at)continue;if(at==0)text.Inlines.Clear();text.Inlines.Add(new System.Windows.Documents.Run(passage[at..pos]));text.Inlines.Add(new System.Windows.Documents.Bold(new System.Windows.Documents.Run(word)));at=pos+word.Length;}if(at>0)text.Inlines.Add(new System.Windows.Documents.Run(passage[at..]));}
     if(code&&!owner.prefs.ReadCode){text.Margin=new W.Thickness(12,7,12,7);readerLines.Children.Add(text);continue;}
     int target=index++;var button=Button("Read sentence: "+passage,()=>{},style:"Plain");button.Content=text;button.HorizontalContentAlignment=W.HorizontalAlignment.Stretch;button.Padding=new W.Thickness(12,7,12,7);button.Margin=new W.Thickness(0,0,0,10);
     button.PreviewMouseLeftButtonDown+=(_,e)=>{if(e.ClickCount==2){owner.ShowEditor();e.Handled=true;}};
     button.Click+=(_,_)=>{if(!editing)_ =owner.Safe(()=>owner.StartReading(target));};
     sentenceButtons.Add(button);readerLines.Children.Add(button);
    }
   }lastSentence=-2;
  }
  C.ComboBox BindCombo(ComboBox source)
  {
   var view=new C.ComboBox{MinWidth=150,HorizontalAlignment=W.HorizontalAlignment.Stretch};comboBindings.Add((view,source));
   view.SelectionChanged+=(_,_)=>{if(!syncingView&&view.SelectedIndex>=0&&view.SelectedIndex<source.Items.Count)source.SelectedIndex=view.SelectedIndex;};return view;
  }
  C.Grid Field(string label,W.FrameworkElement value)
  {
   var row=new C.Grid{Margin=new W.Thickness(0,6,0,6)};row.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new W.GridLength(190)});row.ColumnDefinitions.Add(new C.ColumnDefinition());
   var caption=Text(label);caption.Margin=new W.Thickness(0,0,14,0);caption.VerticalAlignment=W.VerticalAlignment.Center;row.Children.Add(caption);C.Grid.SetColumn(value,1);row.Children.Add(value);W.Automation.AutomationProperties.SetName(value,label);return row;
  }
  C.StackPanel Group(C.Panel parent,string heading)
  {
   var title=Text(heading,13,true);title.Margin=new W.Thickness(5,20,0,8);parent.Children.Add(title);var stack=new C.StackPanel();parent.Children.Add(new C.Border{Child=stack,Padding=new W.Thickness(16,8,16,8),Background=M.Brushes.White,BorderBrush=Line,BorderThickness=new W.Thickness(1),CornerRadius=new W.CornerRadius(9)});return stack;
  }
  static void Note(C.Panel group,string text){var note=Text(text,12);note.Foreground=Secondary;note.Margin=new W.Thickness(0,6,0,7);group.Children.Add(note);}
  string HardwareText()=>ModelGuidance.Hardware(owner.availableGpus,owner.prefs.PreferredGpu);
  C.Grid ModelLibrary()
  {
   var library=new C.Grid{Background=Brush("#F7F7F8")};library.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});library.RowDefinitions.Add(new C.RowDefinition());library.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});
   var intro=new C.StackPanel{Margin=new W.Thickness(24,18,24,12)};hardwareSummary.Foreground=Secondary;intro.Children.Add(hardwareSummary);Note(intro,"One install includes CPU and GPU support for recognition. Automatic uses your GPU when available and switches to CPU if it cannot run.");library.Children.Add(intro);
   modelRows.Margin=new W.Thickness(24,0,24,20);var scroll=new C.ScrollViewer{Content=modelRows};C.Grid.SetRow(scroll,1);library.Children.Add(scroll);
   var footer=new C.DockPanel{Margin=new W.Thickness(20,12,20,12)};var refresh=Button("Refresh",()=>_ =owner.Safe(owner.RefreshModels));C.DockPanel.SetDock(refresh,C.Dock.Right);footer.Children.Add(refresh);var offline=Text("Installed models run offline.",12);offline.Foreground=Secondary;offline.VerticalAlignment=W.VerticalAlignment.Center;footer.Children.Add(offline);C.Grid.SetRow(footer,2);library.Children.Add(footer);return library;
  }
  void RenderModels()
  {
   modelRows.Children.Clear();modelActions.Clear();
   var reading=Group(modelRows,"Reading");AddModelRow(reading,"Windows System Voice","Built in · no download required","Fastest start · CPU · Uses your installed Windows voices.",null,true);
   foreach(var category in new[]{("tts","Reading"),("stt","Dictation & transcription"),("rewrite","Optional wording")}){
    var entries=owner.models.Where(m=>m.Task==category.Item1&&m.VariantOf==null).ToList();if(entries.Count==0)continue;
    var group=category.Item1=="tts"?reading:Group(modelRows,category.Item2);
    foreach(var model in entries){
     if(group.Children.Count>0)group.Children.Add(Divider());
     string size=$"{(model.BundleSizeMB>0?model.BundleSizeMB:model.SizeMB):0} MB";
     AddModelRow(group,model.Name,size+" · "+ModelGuidance.Acceleration(model),ModelGuidance.Recommendation(model),model,model.Installed);
    }
   }
  }
  void AddModelRow(C.Panel parent,string name,string metadata,string description,Model? model,bool installed)
  {
   var row=new C.Grid{Margin=new W.Thickness(0,13,0,13)};row.ColumnDefinitions.Add(new C.ColumnDefinition());row.ColumnDefinitions.Add(new C.ColumnDefinition{Width=W.GridLength.Auto});
   var info=new C.StackPanel{Margin=new W.Thickness(0,0,16,0)};info.Children.Add(Text(name,14));Note(info,metadata);var detail=Text(description,12);detail.Foreground=Secondary;info.Children.Add(detail);row.Children.Add(info);
   var actions=new C.StackPanel{VerticalAlignment=W.VerticalAlignment.Center,MinWidth=84};C.Grid.SetColumn(actions,1);
   if(installed){var state=Text(model!=null&&!model.BundleComplete?"Setup incomplete":"Installed",11);state.Foreground=Secondary;state.HorizontalAlignment=W.HorizontalAlignment.Right;state.Margin=new W.Thickness(0,0,0,6);actions.Children.Add(state);}
   if(model!=null){
    if(!model.BundleComplete){var install=Button(installed?"Complete installation":"Install",()=>_ =owner.Safe(()=>owner.ModelOperation(model.Id,"install")));actions.Children.Add(install);modelActions.Add(install);}
    if(installed){var remove=Button("Remove",()=>_ =owner.Safe(()=>owner.ModelOperation(model.Id,"remove")));remove.Margin=new W.Thickness(0,6,0,0);actions.Children.Add(remove);modelActions.Add(remove);}
   }else{var check=Symbol("checkmark.circle",19);check.HorizontalAlignment=W.HorizontalAlignment.Right;actions.Children.Add(check);}
   row.Children.Add(actions);parent.Children.Add(row);
  }

  void OpenSettings()
  {
   if(settingsWindow!=null){settingsWindow.Activate();return;}
   settingsWindow=new W.Window{Title="DAVE — Settings",Width=780,Height=780,MinWidth=650,MinHeight=500,FontFamily=FontFamily,FontSize=13,Background=Brush("#F5F5F7"),WindowStartupLocation=W.WindowStartupLocation.CenterOwner};
   settingsWindow.Resources.MergedDictionaries.Add(Resources);new System.Windows.Interop.WindowInteropHelper(settingsWindow){Owner=owner.Handle};
   var sections=new C.StackPanel{Margin=new W.Thickness(24,0,24,24)};
   var intro=Group(sections,"DAVE — Dictation And Voice Engine");Note(intro,"Everything on your device.");
   var voices=Group(sections,"Voices");voices.Children.Add(Field("Voice model",BindCombo(owner.readingModel)));voices.Children.Add(voiceRows);Note(voices,"Preview at normal speed, then select a voice for reading. Download additional reading models in Models to try more voices.");
   var reading=Group(sections,"Reading & dictation");reading.Children.Add(Field("Dictation model",BindCombo(owner.dictationModel)));
   var ahead=new C.ComboBox{ItemsSource=Enumerable.Range(3,8).Select(n=>$"{n} sentences").ToArray(),SelectedIndex=owner.prefs.ReadAhead-3};ahead.SelectionChanged+=(_,_)=>{owner.prefs.ReadAhead=ahead.SelectedIndex+3;owner.Save();};reading.Children.Add(Field("Generate ahead",ahead));Note(reading,"Prepares upcoming sentences while reading. More sentences make forward skipping quicker.");
   var code=new C.CheckBox{Content="Read code blocks aloud",IsChecked=owner.prefs.ReadCode};code.Checked+=(_,_)=>{owner.prefs.ReadCode=true;owner.Save();};code.Unchecked+=(_,_)=>{owner.prefs.ReadCode=false;owner.Save();};reading.Children.Add(code);
   var files=Group(sections,"Transcription");files.Children.Add(Field("Audio-file model",BindCombo(owner.transcriptionModel)));Note(files,"Independent of dictation. For several people, start with Whisper Small or above and turn on Distinguish speakers in Transcribe.");
   var acceleration=Group(sections,"Acceleration");Note(acceleration,HardwareText());acceleration.Children.Add(Field("Dictation",BindCombo(owner.dictationDevice)));acceleration.Children.Add(Field("Transcription",BindCombo(owner.transcriptionDevice)));acceleration.Children.Add(Field("Preferred GPU",BindCombo(owner.gpuChoice)));Note(acceleration,"Automatic (recommended) tries the selected NVIDIA GPU, then falls back to CPU. Automatic GPU selection prefers the GPU with the most dedicated memory. AMD and Intel graphics use CPU with this engine. Reading voices and speaker identification use CPU.");
   var shortcuts=Group(sections,"Global shortcuts");readShortcutView=Shortcut(true);dictationShortcutView=Shortcut(false);shortcuts.Children.Add(Field("Read selected text",readShortcutView));shortcuts.Children.Add(Field("Start / finish dictation",dictationShortcutView));Note(shortcuts,"Click a shortcut and press Ctrl, Alt or Shift with a letter. Escape cancels.");
   var position=new C.ComboBox{ItemsSource=new[]{"Bottom of screen","Top of screen"},SelectedIndex=owner.prefs.OverlayAtTop?1:0};position.SelectionChanged+=(_,_)=>{owner.prefs.OverlayAtTop=position.SelectedIndex==1;owner.Save();};shortcuts.Children.Add(Field("Compact controls",position));
   var permissions=Group(sections,"Permissions");permissions.Children.Add(Button("Open Microphone Settings",()=>Invoke("Open microphone privacy settings")));var verify=Button("Verify Shortcuts & Microphone",()=>Invoke("Verify shortcuts and microphone access"));verify.Margin=new W.Thickness(0,8,0,0);permissions.Children.Add(verify);Note(permissions,"Shortcuts work across your desktop. Apps running as administrator may require you to paste manually.");
   settingsScroll=new C.ScrollViewer{Content=sections};settingsWindow.Content=settingsScroll;
   settingsWindow.Closed+=(_,_)=>{StopPreview();comboBindings.RemoveAll(pair=>!IsDescendantOf(pair.View,root));voiceRows.Children.Clear();if(voiceRows.Parent is C.Panel parent)parent.Children.Remove(voiceRows);renderedVoices="";settingsWindow=null;settingsScroll=null;owner.RegisterShortcuts();};
   if(!owner.servicesEnabled){settingsWindow.WindowStartupLocation=W.WindowStartupLocation.Manual;settingsWindow.Left=-30000;settingsWindow.Top=-30000;settingsWindow.ShowActivated=false;}
   settingsWindow.Show();RefreshState();
  }
  public void ShowSettings()=>OpenSettings();
  static bool IsDescendantOf(W.DependencyObject child,W.DependencyObject ancestor){for(W.DependencyObject? current=child;current!=null;current=M.VisualTreeHelper.GetParent(current))if(current==ancestor)return true;return false;}
  C.Button Shortcut(bool reading)
  {
   var button=Button(Native.ShortcutName(reading?owner.prefs.ReadModifiers:owner.prefs.DictateModifiers,reading?owner.prefs.ReadKey:owner.prefs.DictateKey),()=>{});bool capturing=false;
   void Finish(){capturing=false;button.Content=Native.ShortcutName(reading?owner.prefs.ReadModifiers:owner.prefs.DictateModifiers,reading?owner.prefs.ReadKey:owner.prefs.DictateKey);owner.RegisterShortcuts();}
   button.Click+=(_,_)=>{Native.UnregisterHotKey(owner.Handle,1);Native.UnregisterHotKey(owner.Handle,2);capturing=true;button.Content="Press shortcut…";button.Focus();};
   button.PreviewKeyDown+=(_,e)=>{
    if(!capturing)return;e.Handled=true;var key=e.Key==Input.Key.System?e.SystemKey:e.Key;if(key==Input.Key.Escape){Finish();return;}
    if(key is Input.Key.LeftCtrl or Input.Key.RightCtrl or Input.Key.LeftShift or Input.Key.RightShift or Input.Key.LeftAlt or Input.Key.RightAlt)return;
    var modifiers=Input.Keyboard.Modifiers;uint mods=(modifiers.HasFlag(Input.ModifierKeys.Control)?2u:0)|(modifiers.HasFlag(Input.ModifierKeys.Alt)?1u:0)|(modifiers.HasFlag(Input.ModifierKeys.Shift)?4u:0);uint value=(uint)Input.KeyInterop.VirtualKeyFromKey(key);
    if(mods==0){button.Content="Include Ctrl, Alt or Shift";return;}
    if(mods==(reading?owner.prefs.DictateModifiers:owner.prefs.ReadModifiers)&&value==(reading?owner.prefs.DictateKey:owner.prefs.ReadKey)){button.Content="Choose a different shortcut";return;}
    int id=reading?1:2;if(!Native.RegisterHotKey(owner.Handle,id,mods|0x4000,value)){button.Content="Shortcut in use — try another";return;}Native.UnregisterHotKey(owner.Handle,id);
    if(reading){owner.prefs.ReadModifiers=mods;owner.prefs.ReadKey=value;}else{owner.prefs.DictateModifiers=mods;owner.prefs.DictateKey=value;}owner.Save();Finish();
   };button.LostKeyboardFocus+=(_,_)=>{if(capturing)Finish();};return button;
  }
  string? previewVoice;CancellationTokenSource? previewCancel;
  public void CancelVoicePreview()=>StopPreview();
  void StopPreview(){if(previewCancel==null&&previewVoice==null)return;previewCancel?.Cancel();previewCancel=null;previewVoice=null;renderedVoices="";owner.player.Stop();owner.systemVoice.SpeakAsyncCancelAll();}
  void RenderVoices()
  {
   voiceRows.Children.Clear();
   foreach(var voice in owner.voices.Items.Cast<Voice>()){
    var row=new C.DockPanel{Margin=new W.Thickness(0,5,0,5)};var sample=Button(previewVoice==voice.Id?"Stop":"Sample",()=>{
     if(previewVoice==voice.Id){StopPreview();return;}
     _ =owner.Safe(async()=>{StopPreview();owner.StopReading();using var cancellation=new CancellationTokenSource();previewCancel=cancellation;previewVoice=voice.Id;renderedVoices="";
      try{if(owner.prefs.ReadingModel=="system"){
        owner.systemVoice.SelectVoice(voice.Id);owner.systemVoice.Rate=0;
        var completed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);EventHandler<System.Speech.Synthesis.SpeakCompletedEventArgs> handler=(_,e)=>{if(e.Error!=null)completed.TrySetException(e.Error);else completed.TrySetResult();};
        owner.systemVoice.SpeakCompleted+=handler;try{owner.systemVoice.SpeakAsync("This is a sample of your local reading voice.");await completed.Task.WaitAsync(cancellation.Token);}finally{owner.systemVoice.SpeakCompleted-=handler;}
       }else{var result=await owner.readerEngine.Request("synthesize",new{model=owner.prefs.ReadingModel,voice=voice.Id,text="This is a sample of your local reading voice."},cancellation.Token,keepAlive:true);cancellation.Token.ThrowIfCancellationRequested();await owner.player.Play(result.GetProperty("path").GetString()!,1).WaitAsync(cancellation.Token);}}
      finally{if(ReferenceEquals(previewCancel,cancellation)){previewCancel=null;previewVoice=null;renderedVoices="";owner.UpdateRate();}}
     });
    },previewVoice==voice.Id?"stop.fill":"play.fill");C.DockPanel.SetDock(sample,C.Dock.Right);row.Children.Add(sample);
    sample.IsEnabled=!owner.recorder.Active&&!owner.recordingFinishing&&!owner.working;
    var select=Button(voice.Name,()=>owner.voices.SelectedItem=voice,ReferenceEquals(owner.voices.SelectedItem,voice)?"checkmark.circle":"circle","Plain");select.HorizontalContentAlignment=W.HorizontalAlignment.Left;row.Children.Add(select);voiceRows.Children.Add(row);
   }
  }
  C.Grid? library;
  C.Border? suggestionPanel;
  public void ShowSuggestion(string original,string suggestion)
  {
   if(suggestionPanel!=null)dictation.Children.Remove(suggestionPanel);
   if(dictation.RowDefinitions.Count==4)dictation.RowDefinitions.Add(new C.RowDefinition{Height=W.GridLength.Auto});
   var content=new C.StackPanel();content.Children.Add(Text("Suggested wording",14,true));var text=Text(suggestion,14);text.Margin=new W.Thickness(0,10,0,12);content.Children.Add(text);
   void Dismiss(){if(suggestionPanel!=null){dictation.Children.Remove(suggestionPanel);suggestionPanel=null;}}
   var actions=Horizontal();actions.Children.Add(Button("Use Suggestion",()=>{if(owner.dictated.Text!=original){owner.Toast("Text changed. Request a new suggestion.");return;}owner.dictated.Text=suggestion;Dismiss();}));Gap(actions);actions.Children.Add(Button("Dismiss",Dismiss));content.Children.Add(actions);
   suggestionPanel=new C.Border{CornerRadius=new W.CornerRadius(10),Padding=new W.Thickness(16),Background=Brush("#F1F1F3"),Child=new C.ScrollViewer{Content=content,MaxHeight=220},Margin=new W.Thickness(0,12,0,0)};C.Grid.SetRow(suggestionPanel,4);dictation.Children.Add(suggestionPanel);
  }
  public string? Prompt(string title,string description)
  {
   var dialog=new W.Window{Title=title,Width=440,SizeToContent=W.SizeToContent.Height,ResizeMode=W.ResizeMode.NoResize,WindowStartupLocation=W.WindowStartupLocation.CenterOwner,FontSize=13,FontFamily=FontFamily};dialog.Resources.MergedDictionaries.Add(Resources);new System.Windows.Interop.WindowInteropHelper(dialog){Owner=owner.Handle};
   var panel=new C.StackPanel{Margin=new W.Thickness(24)};panel.Children.Add(Text(description));var input=new C.TextBox{MaxLength=80,Margin=new W.Thickness(0,16,0,16)};panel.Children.Add(input);var actions=Horizontal();actions.HorizontalAlignment=W.HorizontalAlignment.Right;var save=Button("Save",()=>{if(!string.IsNullOrWhiteSpace(input.Text))dialog.DialogResult=true;},style:"Primary");save.IsDefault=true;var cancel=Button("Cancel",()=>dialog.DialogResult=false);cancel.IsCancel=true;actions.Children.Add(cancel);Gap(actions);actions.Children.Add(save);panel.Children.Add(actions);dialog.Content=panel;dialog.Loaded+=(_,_)=>input.Focus();return dialog.ShowDialog()==true?input.Text:null;
  }
  public bool CorrectSpeaker(Caption caption)
  {
   var dialog=new W.Window{Title="Correct this passage",Width=480,SizeToContent=W.SizeToContent.Height,ResizeMode=W.ResizeMode.NoResize,WindowStartupLocation=W.WindowStartupLocation.CenterOwner,FontSize=13,FontFamily=FontFamily};dialog.Resources.MergedDictionaries.Add(Resources);new System.Windows.Interop.WindowInteropHelper(dialog){Owner=owner.Handle};
   var panel=new C.StackPanel{Margin=new W.Thickness(24)};panel.Children.Add(Text("Assign only this passage. Confirmed examples help other uncertain passages."));var ids=owner.transcript.Speakers;var choices=new C.ComboBox{ItemsSource=ids.Select(owner.transcript.Name).Append("New person…").ToArray(),SelectedIndex=Array.IndexOf(ids,caption.Speaker),Margin=new W.Thickness(0,16,0,16)};panel.Children.Add(choices);
   var name=new C.TextBox{MaxLength=80,Visibility=W.Visibility.Collapsed,Margin=new W.Thickness(0,0,0,16)};W.Automation.AutomationProperties.SetName(name,"New speaker name");panel.Children.Add(name);choices.SelectionChanged+=(_,_)=>name.Visibility=choices.SelectedIndex==ids.Length?W.Visibility.Visible:W.Visibility.Collapsed;
   var actions=Horizontal();actions.HorizontalAlignment=W.HorizontalAlignment.Right;var cancel=Button("Cancel",()=>dialog.DialogResult=false);cancel.IsCancel=true;actions.Children.Add(cancel);Gap(actions);var confirm=Button("Confirm passage",()=>{int index=choices.SelectedIndex;if(index<0||index==ids.Length&&string.IsNullOrWhiteSpace(name.Text))return;owner.transcript.Correct(caption.Id,index<ids.Length?ids[index]:null,name.Text);dialog.DialogResult=true;},style:"Primary");confirm.IsDefault=true;actions.Children.Add(confirm);panel.Children.Add(actions);dialog.Content=panel;return dialog.ShowDialog()==true;
  }
  public void RefreshState()
  {
   if(owner.IsDisposed)return;
   int target=owner.tabs.SelectedIndex;
   if(target==4){OpenSettings();owner.tabs.SelectedIndex=selectedPage<0?0:selectedPage;target=owner.tabs.SelectedIndex;}
   if(target!=selectedPage){selectedPage=target;title.Text=new[]{"Read","Dictate","Transcribe","Models"}[target];page.Content=target switch{0=>reader,1=>dictation,2=>transcription,_=>library??=ModelLibrary()};toolbar.Children.Clear();
    if(target==0){toolbar.Children.Add(IconButton("Open text or Markdown file","doc.badge.plus",()=>Invoke("Open document")));toolbar.Children.Add(IconButton("Paste text","doc.on.clipboard",Paste));Gap(toolbar,12);toolbar.Children.Add(play);toolbar.Children.Add(stop);}
    for(int i=0;i<navigation.Count;i++)navigation[i].Background=i==target?Brush("#DCDCE0"):M.Brushes.Transparent;
   }
   UpdateReader();
   bool active=owner.readingCancel!=null;
   play.Content=ButtonLabel(active?owner.readingPaused?"Resume":"Pause":"Read",active&&!owner.readingPaused?"pause.fill":"play.fill");play.IsEnabled=owner.editor.Text.Trim().Length>0;stop.IsEnabled=active;
   speed.Content=$"Speed {owner.prefs.Rate:0.#}×";previous.IsEnabled=owner.readingIndex>0;next.IsEnabled=owner.sentences.Items.Count>0&&owner.readingIndex<owner.sentences.Items.Count-1;readStatus.Text=active?owner.readingStatus.Text:"Ready";
   if(active){owner.overlay.SetReading(()=>Skip(-1),()=>Skip(1),()=>Invoke(owner.speedButton),owner.prefs.Rate,owner.readingPaused,previous.IsEnabled,next.IsEnabled);owner.overlay.Status.Text=owner.readingPaused?"Paused":owner.readingStatus.Text.StartsWith("Generating")?"Generating speech…":"Reading";}
   generationPanel.Visibility=active?W.Visibility.Visible:W.Visibility.Collapsed;
   generationText.Text=$"{Math.Max(0,owner.generated.Values.Count(t=>t.IsCompletedSuccessfully)-1)} sentences ready ahead · target {owner.prefs.ReadAhead}"+(owner.readingStatus.Text.StartsWith("Generating")?"\nGenerating speech on this PC…":"");
   int selected=active?owner.readingIndex:-1;if(selected!=lastSentence){for(int i=0;i<sentenceButtons.Count;i++)sentenceButtons[i].Background=i==selected?Brush("#E0EEFF"):M.Brushes.Transparent;if(selected>=0&&selected<sentenceButtons.Count&&target==0&&!editing)sentenceButtons[selected].BringIntoView();lastSentence=selected;}
   syncingView=true;
   try{
    foreach(var pair in comboBindings){var items=pair.Source.Items.Cast<object>().ToArray();if(pair.View.Items.Count!=items.Length||pair.View.Items.Cast<object>().Where((value,i)=>!ReferenceEquals(value,items[i])).Any())pair.View.ItemsSource=items;pair.View.SelectedIndex=pair.Source.SelectedIndex;pair.View.IsEnabled=pair.Source.Enabled;}
    if(transcriptEditor.Text!=owner.dictated.Text)transcriptEditor.Text=owner.dictated.Text;
    if(separateView!=null){separateView.IsChecked=owner.separate.Checked;separateView.IsEnabled=owner.separate.Enabled;}
    if(peopleView!=null){peopleView.SelectedIndex=(int)owner.speakerCount.Value;peopleView.IsEnabled=owner.speakerCount.Enabled;}
   }finally{syncingView=false;}
   foreach(var pair in buttonBindings)pair.View.IsEnabled=pair.Source.Enabled;
   record.Content=Symbol(owner.recorder.Active?"stop.fill":"mic.fill",23,M.Brushes.White);record.Background=owner.recorder.Active?Brush("#FF453A"):Accent;record.IsEnabled=!owner.recordingFinishing&&!owner.working;
   W.Automation.AutomationProperties.SetName(record,owner.recorder.Active?"Finish dictation":"Start dictation");dictationTitle.Text=owner.recorder.Active?"Listening":owner.recordingFinishing?"Transcribing…":"Speak naturally";dictationHint.Text=owner.recorder.Active?"Press Enter or the microphone to finish.":"Your voice stays on this PC.";
   cancelRecording.Visibility=owner.recorder.Active||owner.recordingFinishing?W.Visibility.Visible:W.Visibility.Collapsed;copyDictation.IsEnabled=readBack.IsEnabled=owner.dictated.Text.Length>0;suggest.IsEnabled=copyDictation.IsEnabled&&!owner.recordingFinishing&&!owner.recorder.Active;
   speakerOptions.Visibility=owner.separate.Checked?W.Visibility.Visible:W.Visibility.Collapsed;
   audioTitle.Text=owner.audioPath==null?"Transcribe audio":Path.GetFileName(owner.audioPath);audioHint.Text=$"{(owner.transcriptionModel.SelectedItem as Model)?.Name??"Whisper"} · Audio stays on this PC";
   transcribe.Content=owner.working?"Cancel":"Transcribe";transcribe.IsEnabled=owner.audioPath!=null;listen.IsEnabled=owner.audioPath!=null;listen.Content=owner.filePlayer.Playing?"Pause":"Listen";export.IsEnabled=owner.transcript.Captions.Count>0;transcriptionStatus.Text=owner.transcribeStatus.Text;
   transcriptionProgress.Visibility=owner.working?W.Visibility.Visible:W.Visibility.Collapsed;transcriptionProgress.Value=owner.transcribeProgress.Value;
   string captions=string.Join("|",owner.transcript.Captions.Select(c=>$"{c.Id}:{c.Text}:{owner.transcript.Name(c.Speaker)}:{c.Confirmed}"));
   if(captions!=renderedCaptions||captionRows.Children.Count==0){renderedCaptions=captions;RenderCaptions();}
   var modelStamp=string.Join("|",owner.models.Select(m=>$"{m.Id}:{m.Installed}:{m.BundleComplete}"));if(modelStamp!=renderedModels||modelRows.Children.Count==0){renderedModels=modelStamp;RenderModels();}
   hardwareSummary.Text=HardwareText();foreach(var button in modelActions)button.IsEnabled=owner.modelList.Enabled&&!active&&!owner.working&&!owner.recorder.Active&&!owner.recordingFinishing;
   if(settingsWindow!=null){var stamp=owner.prefs.ReadingModel+":"+owner.voices.SelectedIndex+":"+string.Join("|",owner.voices.Items.Cast<object>())+":"+previewVoice+":"+owner.recorder.Active+":"+owner.working;if(stamp!=renderedVoices){renderedVoices=stamp;RenderVoices();}}
   toastText.Text=owner.notice.Text;toast.Visibility=owner.notice.Text.Length>0&&owner.noticeUntil>DateTime.UtcNow?W.Visibility.Visible:W.Visibility.Collapsed;
  }
  W.FrameworkElement ButtonLabel(string label,string icon){var panel=Horizontal();panel.Children.Add(Symbol(icon));Gap(panel,6);panel.Children.Add(Text(label));return panel;}
  void RenderCaptions()
  {
   captionRows.Children.Clear();
   if(owner.transcript.Captions.Count==0){var empty=new C.StackPanel{Margin=new W.Thickness(30,42,30,30),HorizontalAlignment=W.HorizontalAlignment.Center};var icon=Symbol("waveform.badge.magnifyingglass",40);icon.HorizontalAlignment=W.HorizontalAlignment.Center;empty.Children.Add(icon);var label=Text(owner.audioPath==null?"Open a recording to get started":"Ready to transcribe",20);label.Margin=new W.Thickness(0,16,0,12);empty.Children.Add(label);Note(empty,"Your audio is processed on this PC.");captionRows.Children.Add(empty);return;}
   foreach(var caption in owner.transcript.Captions){
    var row=new C.Grid{Margin=new W.Thickness(20,9,20,9)};row.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new W.GridLength(76)});row.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new W.GridLength(125)});row.ColumnDefinitions.Add(new C.ColumnDefinition());
    var time=Button(TimeSpan.FromSeconds(caption.Start).ToString(@"hh\:mm\:ss"),()=>_ =owner.Safe(async()=>{if(owner.audioPath==null)return;if(owner.filePlayer.Duration==0||owner.filePlayer.Finished)await owner.filePlayer.Play(owner.audioPath,1,caption.Start);else owner.filePlayer.Seek(caption.Start);}),style:"Plain");time.FontSize=11;time.VerticalAlignment=W.VerticalAlignment.Top;row.Children.Add(time);
    var person=Button(owner.transcript.Name(caption.Speaker)+(caption.Confirmed?" ✓":""),()=>owner.EditSpeaker(caption),style:"Plain");person.VerticalAlignment=W.VerticalAlignment.Top;person.HorizontalContentAlignment=W.HorizontalAlignment.Left;person.FontSize=12;C.Grid.SetColumn(person,1);row.Children.Add(person);
    var text=Text(caption.Text,15);text.Margin=new W.Thickness(12,5,0,5);text.LineHeight=23;C.Grid.SetColumn(text,2);row.Children.Add(text);captionRows.Children.Add(row);captionRows.Children.Add(Divider());
   }
  }
  void DrawWaveform()
  {
   waveform.Children.Clear();int count=Math.Max(1,(int)(waveform.ActualWidth/5));var history=levels.TakeLast(count).ToArray();
   for(int i=0;i<count;i++){float value=i>=count-history.Length?history[i-(count-history.Length)]:0;double height=Math.Clamp(value*160,3,43);var bar=new System.Windows.Shapes.Rectangle{Width=2.5,Height=height,RadiusX=1.25,RadiusY=1.25,Fill=owner.recorder.Active?Accent:Brush("#C8C8CC"),Opacity=.35+.65*i/count};C.Canvas.SetLeft(bar,i*5);C.Canvas.SetTop(bar,(45-height)/2);waveform.Children.Add(bar);}
  }
  // Original vector geometry following the same semantic symbols as the Mac toolbar.
  // No platform icon font is required, so glyphs remain stable across Windows versions.
  internal static W.FrameworkElement Symbol(string name,double size=18,M.Brush? color=null)
  {
   string data=name switch{
    "book.closed" or "text.book.closed"=>"M5,3 L18,3 Q20,3 20,5 L20,21 L6,21 Q3,21 3,18 L3,6 Q3,3 5,3 M6,3 L6,17 M3,18 Q3,16 6,16 L20,16 M9,7 L16,7 M9,10 L15,10",
    "mic" or "mic.fill"=>"M9,5 Q9,2 12,2 Q15,2 15,5 L15,12 Q15,15 12,15 Q9,15 9,12 Z M6,10 L6,12 Q6,18 12,18 Q18,18 18,12 L18,10 M12,18 L12,22 M8,22 L16,22",
    "waveform.badge.magnifyingglass"=>"M2,9 L2,15 M6,5 L6,19 M10,2 L10,15 M14,6 L14,11 M18,8 L18,11 M19,13 A4,4 0 1 0 19,21 A4,4 0 1 0 19,13 M22,20 L25,23",
    "cpu"=>"M6,5 L18,5 Q19,5 19,6 L19,18 Q19,19 18,19 L6,19 Q5,19 5,18 L5,6 Z M9,9 L15,9 L15,15 L9,15 Z M8,2 L8,5 M12,2 L12,5 M16,2 L16,5 M8,19 L8,22 M12,19 L12,22 M16,19 L16,22 M2,8 L5,8 M2,12 L5,12 M2,16 L5,16 M19,8 L22,8 M19,12 L22,12 M19,16 L22,16",
    "gearshape"=>"M10,2 L14,2 L15,5 L18,6 L21,6 L23,10 L20,12 L20,15 L21,18 L18,21 L15,20 L12,20 L10,23 L6,21 L6,18 L4,15 L1,14 L1,10 L4,9 L6,6 L6,3 Z M16,12 A4,4 0 1 0 8,12 A4,4 0 1 0 16,12",
    "doc.badge.plus"=>"M14,2 L5,2 L5,22 L19,22 L19,7 L14,2 L14,7 L19,7 M8,14 L16,14 M12,10 L12,18",
    "doc.on.clipboard"=>"M8,5 L4,5 L4,22 L18,22 L18,19 M9,3 L20,3 L20,18 L9,18 Z M12,2 L17,2 L17,5 L12,5 Z",
    "play.fill"=>"M7,3 L21,12 L7,21 Z",
    "pause.fill"=>"M6,3 L10,3 L10,21 L6,21 Z M15,3 L19,3 L19,21 L15,21 Z",
    "stop.fill"=>"M5,5 L19,5 L19,19 L5,19 Z",
    "backward.end.fill"=>"M19,4 L7,12 L19,20 Z M4,4 L6,4 L6,20 L4,20 Z",
    "forward.end.fill"=>"M5,4 L17,12 L5,20 Z M18,4 L20,4 L20,20 L18,20 Z",
    "speaker.wave.2"=>"M3,9 L7,9 L13,4 L13,20 L7,15 L3,15 Z M17,8 Q21,12 17,16 M20,4 Q27,12 20,20",
    "checkmark.circle"=>"M22,12 A10,10 0 1 0 2,12 A10,10 0 1 0 22,12 M7,12 L10,15 L17,8",
    "circle"=>"M22,12 A10,10 0 1 0 2,12 A10,10 0 1 0 22,12",
    "xmark"=>"M6,6 L18,18 M18,6 L6,18",
    _=>"M5,12 L19,12"
   };
   var geometry=M.Geometry.Parse(data);var path=new System.Windows.Shapes.Path{Data=geometry,Stroke=color??Brush("#606067"),StrokeThickness=1.5,StrokeStartLineCap=M.PenLineCap.Round,StrokeEndLineCap=M.PenLineCap.Round,StrokeLineJoin=M.PenLineJoin.Round};
   if(name.EndsWith(".fill")&&name!="mic.fill")path.Fill=color??Brush("#606067");
   return new C.Viewbox{Child=new C.Canvas{Width=26,Height=24,Children={path}},Width=size,Height=size,VerticalAlignment=W.VerticalAlignment.Center,Stretch=M.Stretch.Uniform};
  }
 }
}
