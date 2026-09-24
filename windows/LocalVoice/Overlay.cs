using W=System.Windows;
using C=System.Windows.Controls;
using M=System.Windows.Media;
namespace LocalVoice;

internal sealed class Overlay:Form
{
 public readonly Label Status=new();
 readonly C.TextBlock status=new(){FontSize=14,FontWeight=W.FontWeights.Medium,TextWrapping=W.TextWrapping.Wrap,MaxWidth=200};
 readonly C.Button primary=new(),secondary=new(),previous=new(),next=new(),speed=new();
 readonly C.ContentControl icon=new();readonly C.StackPanel controls=new(){Orientation=C.Orientation.Horizontal,VerticalAlignment=W.VerticalAlignment.Center};
 Action? primaryAction,secondaryAction,previousAction,nextAction,speedAction;
 readonly C.Border surface;
 public Overlay()
 {
  AutoScaleMode=AutoScaleMode.Dpi;AutoScaleDimensions=new SizeF(96,96);FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;TopMost=true;BackColor=Color.FromArgb(246,246,248);Size=new Size(460,105);StartPosition=FormStartPosition.Manual;
  var content=new C.DockPanel{Margin=new W.Thickness(20)};
  surface=new C.Border{Background=new M.SolidColorBrush(M.Color.FromRgb(246,246,248)),CornerRadius=new W.CornerRadius(24),BorderBrush=new M.SolidColorBrush(M.Color.FromRgb(220,220,225)),BorderThickness=new W.Thickness(1),Child=content};
  surface.Resources.MergedDictionaries.Add(new W.ResourceDictionary{Source=new Uri("/DAVE;component/MacAppearance.xaml",UriKind.Relative)});
  C.DockPanel.SetDock(controls,C.Dock.Right);content.Children.Add(controls);icon.Margin=new W.Thickness(0,0,14,0);icon.VerticalAlignment=W.VerticalAlignment.Center;C.DockPanel.SetDock(icon,C.Dock.Left);content.Children.Add(icon);
  var information=new C.StackPanel{VerticalAlignment=W.VerticalAlignment.Center};information.Children.Add(status);speed.HorizontalAlignment=W.HorizontalAlignment.Left;speed.Margin=new W.Thickness(0,6,0,0);information.Children.Add(speed);content.Children.Add(information);
  foreach(var button in new[]{previous,next,primary,secondary,speed}){button.Style=(W.Style)surface.FindResource("Plain");button.Padding=new W.Thickness(5);}
  previous.Content=MainForm.WpfPresentation.Symbol("backward.end.fill");next.Content=MainForm.WpfPresentation.Symbol("forward.end.fill");secondary.Content=MainForm.WpfPresentation.Symbol("xmark");
  previous.ToolTip="Previous sentence";next.ToolTip="Next sentence";speed.ToolTip="Playback speed";W.Automation.AutomationProperties.SetName(previous,"Previous sentence");W.Automation.AutomationProperties.SetName(next,"Next sentence");W.Automation.AutomationProperties.SetName(speed,"Playback speed");
  foreach(var button in new[]{previous,next,primary,secondary})controls.Children.Add(button);
  primary.Click+=(_,_)=>primaryAction?.Invoke();secondary.Click+=(_,_)=>secondaryAction?.Invoke();previous.Click+=(_,_)=>previousAction?.Invoke();next.Click+=(_,_)=>nextAction?.Invoke();speed.Click+=(_,_)=>speedAction?.Invoke();
  Status.TextChanged+=(_,_)=>status.Text=Status.Text;
  var host=new System.Windows.Forms.Integration.ElementHost{Dock=DockStyle.Fill,Child=surface};Controls.Add(host);
 }
 public void SetControls(string first,Action firstAction,string second,Action secondAction)
 {
  primaryAction=firstAction;secondaryAction=secondAction;primary.ToolTip=first;secondary.ToolTip=second;W.Automation.AutomationProperties.SetName(primary,first);W.Automation.AutomationProperties.SetName(secondary,second);
  bool reading=first.Contains("Pause");primary.Content=MainForm.WpfPresentation.Symbol(reading?"pause.fill":"stop.fill");icon.Content=MainForm.WpfPresentation.Symbol(reading?"speaker.wave.2":"mic",24);
  foreach(var control in new C.Button[]{speed,previous,next})control.Visibility=reading?W.Visibility.Visible:W.Visibility.Collapsed;
 }
 public void SetReading(Action backward,Action forward,Action changeSpeed,double rate,bool paused,bool canBack,bool canForward)
 {
  previousAction=backward;nextAction=forward;speedAction=changeSpeed;speed.Content=$"Speed {rate:0.#}×";previous.IsEnabled=canBack;next.IsEnabled=canForward;
  primary.Content=MainForm.WpfPresentation.Symbol(paused?"play.fill":"pause.fill");W.Automation.AutomationProperties.SetName(primary,paused?"Resume reading":"Pause reading");
 }
 public void Present(bool atTop)
 {
  var screen=Screen.FromHandle(Native.GetForegroundWindow()).WorkingArea;double scale=DeviceDpi/96d;Size=new Size((int)(460*scale),(int)(105*scale));Location=new Point(screen.Left+(screen.Width-Width)/2,atTop?screen.Top+24:screen.Bottom-Height-24);Show();
 }
 protected override void OnResize(EventArgs e)
 {
  base.OnResize(e);if(Width<48||Height<48)return;int d=(int)(48*DeviceDpi/96d);using var path=new System.Drawing.Drawing2D.GraphicsPath();path.AddArc(0,0,d,d,180,90);path.AddArc(Width-d,0,d,d,270,90);path.AddArc(Width-d,Height-d,d,d,0,90);path.AddArc(0,Height-d,d,d,90,90);path.CloseFigure();var old=Region;Region=new Region(path);old?.Dispose();
 }
 internal void Render(string path){surface.UpdateLayout();var bitmap=new M.Imaging.RenderTargetBitmap((int)surface.ActualWidth,(int)surface.ActualHeight,96,96,M.PixelFormats.Pbgra32);bitmap.Render(surface);var encoder=new M.Imaging.PngBitmapEncoder();encoder.Frames.Add(M.Imaging.BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);}
 protected override bool ShowWithoutActivation=>true;
 protected override CreateParams CreateParams{get{var p=base.CreateParams;p.ExStyle|=0x08000000|0x80;return p;}}
}

