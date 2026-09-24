using System.IO;
using LocalVoice;
using System.Reflection;
using W=System.Windows;
using C=System.Windows.Controls;
using M=System.Windows.Media;

internal static class Program
{
 const BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
 static object Field(object target,string name)=>target.GetType().GetField(name,Private|BindingFlags.Public)!.GetValue(target)!;
 static object? Call(object target,string method,params object[] args)=>target.GetType().GetMethod(method,Private|BindingFlags.Public)!.Invoke(target,args);
 [STAThread] static void Main(string[] args)
 {
  ApplicationConfiguration.Initialize();
  string output=Path.GetFullPath(args.FirstOrDefault()??"test-results/windows-ui");Directory.CreateDirectory(output);
  try
  {
   AudioChecks.Run();if(args.Contains("--speech-samples"))AudioChecks.WriteSpeechSamples(Path.Combine(output,"audio"));
   using var form=new MainForm(false);
   form.StartPosition=FormStartPosition.Manual;form.Location=new Point(-30000,-30000);form.Show();
   var view=(C.UserControl)Field(form,"presentation");var navigation=Field(form,"tabs");var selection=navigation.GetType().GetProperty("SelectedIndex")!;
   form.ClientSize=new Size((int)(1040*form.DeviceDpi/96d),(int)(740*form.DeviceDpi/96d));
   Call(form,"RenderPresentation",Path.Combine(output,"reader-empty.png"));
   typeof(MainForm).GetField("syncing",Private)!.SetValue(form,true);
   var models=(List<Model>)Field(form,"models");models.AddRange(new[]{new Model{Id="kokoro-q8",Name="Kokoro",Task="tts",Installed=true,BundleComplete=true,SizeMB=88},new Model{Id="whisper-tiny",Name="Whisper Tiny English",Task="stt",Installed=true,BundleComplete=false,BundleSizeMB=116},new Model{Id="whisper-small",Name="Whisper Small",Task="stt",BundleSizeMB=740},new Model{Id="whisper-large-v3-turbo",Name="Whisper Large v3 Turbo",Task="stt",BundleSizeMB=1700}});
   foreach(var pair in new[]{("readingModel",models[0]),("dictationModel",models[1]),("transcriptionModel",models[2])}){var combo=(ComboBox)Field(form,pair.Item1);combo.Items.Add(pair.Item2);combo.SelectedIndex=0;}
   var voices=(ComboBox)Field(form,"voices");voices.Items.AddRange(new object[]{new Voice{Id="af_heart",Name="Heart · American English"},new Voice{Id="af_bella",Name="Bella · American English"}});voices.SelectedIndex=0;
   ((List<GpuDevice>)Field(form,"availableGpus")).Add(new GpuDevice{Id="GPU-test",Name="NVIDIA GeForce RTX 3090",MemoryMB=24576});
   typeof(MainForm).GetField("syncing",Private)!.SetValue(form,false);
   var editor=(RichTextBox)Field(form,"editor");editor.Text="# A quieter way to work\nRead, dictate, and transcribe entirely on this computer.\n\n## Everything on your device\n**Local voices** keep your writing private. Click a sentence to listen, or double-click to edit.\n\n```js\nconst privateAudio = true;\n```";
   Call(form,"ShowSentences");var reader=Field(form,"sentences");Call(reader,"SetDocument",editor.Text,false);var items=(List<string>)reader.GetType().GetProperty("Items")!.GetValue(reader)!;if(items.Any(x=>x.Contains("privateAudio")))throw new Exception("Code reading must be optional.");Call(reader,"SetDocument",editor.Text,true);if(!items.Any(x=>x.Contains("privateAudio")))throw new Exception("Code preference ignored.");
   var transcript=(Transcript)Field(form,"transcript");transcript.Captions.Add(new Caption{Start=0,End=5,Speaker="Speaker 1",Text="Your recording stays on this computer. Click a timestamp to listen, or a speaker to correct their name."});Call(form,"RefreshCaptions");
   foreach(int width in new[]{760,1040}){
    form.ClientSize=new Size((int)(width*form.DeviceDpi/96d),(int)(740*form.DeviceDpi/96d));
    for(int page=0;page<4;page++){
     selection.SetValue(navigation,page);Call(form,"RenderPresentation",Path.Combine(output,$"page-{page}-{width}.png"));CheckLayout(view);
    }
   }
   selection.SetValue(navigation,0);Call(form,"ShowEditor");Call(form,"RenderPresentation",Path.Combine(output,"reader-edit.png"));
   Call(view,"OpenSettings");var settings=(W.Window)Field(view,"settingsWindow");settings.Left=-30000;settings.Top=-30000;
   Call(view,"RefreshState");settings.UpdateLayout();Render(settings,Path.Combine(output,"settings.png"));CheckLayout(settings);
   var scroll=(C.ScrollViewer)Field(view,"settingsScroll");scroll.ScrollToVerticalOffset(650);settings.UpdateLayout();Render(settings,Path.Combine(output,"settings-acceleration.png"));settings.Close();
   Call(view,"OpenSettings");((W.Window)Field(view,"settingsWindow")).Close();
   var overlay=(Form)Field(form,"overlay");Call(overlay,"SetControls","Pause / resume",(Action)(()=>{}),"Stop",(Action)(()=>{}));Call(overlay,"SetReading",(Action)(()=>{}),(Action)(()=>{}),(Action)(()=>{}),1.2d,false,false,true);((Label)Field(overlay,"Status")).Text="Reading";overlay.Location=new Point(-30000,-30000);overlay.Size=new Size((int)(460*form.DeviceDpi/96d),(int)(105*form.DeviceDpi/96d));overlay.Show();Call(overlay,"Render",Path.Combine(output,"compact.png"));overlay.Hide();
   form.Close();
   File.WriteAllText(Path.Combine(output,"result.txt"),"WINDOWS_UI_OK: WPF reader (empty/edit/read), dictation, transcription, models at 760/1040 logical pixels; settings opened twice; audio tempo/pitch/seek checks passed.");
  }
  catch(Exception e){File.WriteAllText(Path.Combine(output,"result.txt"),e.ToString());Environment.ExitCode=1;}
 }
 static void Render(W.FrameworkElement element,string path){element.Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.Render);var bitmap=new M.Imaging.RenderTargetBitmap((int)element.ActualWidth,(int)element.ActualHeight,96,96,M.PixelFormats.Pbgra32);bitmap.Render(element);var encoder=new M.Imaging.PngBitmapEncoder();encoder.Frames.Add(M.Imaging.BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);}
 static IEnumerable<W.DependencyObject> Descendants(W.DependencyObject parent){for(int i=0;i<M.VisualTreeHelper.GetChildrenCount(parent);i++){var child=M.VisualTreeHelper.GetChild(parent,i);yield return child;foreach(var nested in Descendants(child))yield return nested;}}
 static void CheckLayout(W.FrameworkElement root){foreach(var control in Descendants(root).OfType<C.Control>().Where(c=>c.IsVisible&&c is C.Button or C.ComboBox)){if(control.ActualHeight<23)throw new Exception($"Control too short: {control}");var rect=control.TransformToAncestor(root).TransformBounds(new W.Rect(control.RenderSize));if(rect.Left<-.5||rect.Right>root.ActualWidth+.5)throw new Exception($"Control clips horizontally: {control} at {rect}");}}
}
