using LocalVoice;
using System.Reflection;

internal static class Program
{
 [STAThread] static void Main(string[] args)
 {
  ApplicationConfiguration.Initialize();
  string output=Path.GetFullPath(args.FirstOrDefault()??"test-results/windows-ui");Directory.CreateDirectory(output);
  try
  {
   AudioChecks.Run();
   using var form=new MainForm(false);
   form.StartPosition=FormStartPosition.Manual;form.Location=new Point(-30000,-30000);form.Show();
   // The offscreen form disables startup services: no shortcuts, microphone or inference.
   var navigation=form.Controls.Cast<Control>().Single(c=>c.GetType().Name=="WorkspaceNavigation");
   var selection=navigation.GetType().GetProperty("SelectedIndex")!;
   var editor=(RichTextBox)typeof(MainForm).GetField("editor",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(form)!;
   editor.Text="# A quieter way to work\nRead, dictate, and transcribe entirely on this computer.\n\n## Designed for Windows\n**Local voices** keep your writing private. Click a passage to start reading, or double-click to edit.\n\n\x60\x60\x60js\nconst privateAudio = true;\n\x60\x60\x60";
   typeof(MainForm).GetMethod("ShowSentences",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(form,null);
   var reader=typeof(MainForm).GetField("sentences",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(form)!;
   var setDocument=reader.GetType().GetMethod("SetDocument")!;
   setDocument.Invoke(reader,new object[]{editor.Text,false});
   var items=(List<string>)reader.GetType().GetProperty("Items")!.GetValue(reader)!;
   if(items.Any(x=>x.Contains("privateAudio")))throw new Exception("Code reading must be optional.");
   setDocument.Invoke(reader,new object[]{editor.Text,true});
   if(!items.Any(x=>x.Contains("privateAudio")))throw new Exception("Code reading preference ignored.");
   var transcript=(Transcript)typeof(MainForm).GetField("transcript",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(form)!;
   transcript.Captions.Add(new Caption{Start=0,End=5,Speaker="Speaker 1",Text="Your recording stays on this computer. Click a caption to listen, or a speaker to correct their name."});
   typeof(MainForm).GetMethod("RefreshCaptions",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(form,null);
   foreach(int width in new[]{960,1280})
   {
    form.Size=new Size(width,800);
    for(int page=0;page<5;page++)
    {
     selection.SetValue(navigation,page);form.PerformLayout();
     using var bitmap=new Bitmap(form.Width,form.Height);form.DrawToBitmap(bitmap,new Rectangle(Point.Empty,form.Size));
     bitmap.Save(Path.Combine(output,$"page-{page}-{width}.png"));
     foreach(var button in Descendants(form).OfType<Button>().Where(b=>b.Visible))
     {
      if(button.Height<32)throw new Exception($"Small button: {button.Text}");
      if(button.ForeColor==button.BackColor)throw new Exception($"Unreadable button: {button.Text}");
     }
    }
   }
   var overlay=(Form)typeof(MainForm).GetField("overlay",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(form)!;
   overlay.GetType().GetMethod("SetControls")!.Invoke(overlay,new object[]{"Pause / resume",(Action)(()=>{}),"Stop",(Action)(()=>{})});
   ((Label)overlay.GetType().GetField("Status")!.GetValue(overlay)!).Text="Reading · Speed 1×";
   overlay.Location=new Point(-30000,-30000);overlay.Show();
   using(var image=new Bitmap(overlay.Width,overlay.Height)){overlay.DrawToBitmap(image,new Rectangle(Point.Empty,overlay.Size));image.Save(Path.Combine(output,"compact.png"));}
   form.Close();
   File.WriteAllText(Path.Combine(output,"result.txt"),"WINDOWS_UI_OK: five pages at two window widths; no inference or microphone access.");
  }
  catch(Exception e){File.WriteAllText(Path.Combine(output,"result.txt"),e.ToString());Environment.ExitCode=1;}
 }
 static IEnumerable<Control> Descendants(Control parent){foreach(Control child in parent.Controls){yield return child;foreach(var nested in Descendants(child))yield return nested;}}
}
