using System.Text.RegularExpressions;

namespace LocalVoice;

// RichEdit supplies wrapped text, selection, scrolling and native accessibility.
// Speech uses the same passage boundaries as hit-testing and highlighting.
internal sealed class ReadingView:RichTextBox
{
 public List<string> Items {get;}=new();
 readonly List<(int Start,int Length)> spans=new();
 int selected=-1;
 public ReadingView(){Dock=DockStyle.Fill;ReadOnly=true;BorderStyle=BorderStyle.None;DetectUrls=false;HideSelection=false;Font=new Font("Segoe UI",14);}
 public void SetDocument(string source,bool readCode)
 {
  Clear();Items.Clear();spans.Clear();selected=-1;
  bool code=false;
  foreach(string line in source.Replace("\r","").Split('\n'))
  {
   if(line.TrimStart().StartsWith("```")){code=!code;continue;}
   if(string.IsNullOrWhiteSpace(line)){AppendText("\n");continue;}
   bool heading=!code&&Regex.IsMatch(line,@"^\s{0,3}#{1,6}\s");
   var passages=code?Enumerable.Range(0,(line.Length+1199)/1200).Select(i=>line.Substring(i*1200,Math.Min(1200,line.Length-i*1200))).ToArray():ReadDocument.Sentences(line);
   foreach(string passage in passages)
   {
    int start=TextLength;
    using var font=new Font(code?"Consolas":"Segoe UI",heading?18:code?11:14,heading?FontStyle.Bold:FontStyle.Regular);
    SelectionStart=start;SelectionIndent=16;SelectionRightIndent=16;SelectionFont=font;SelectionColor=WindowsTheme.Ink;SelectionBackColor=SystemColors.Window;
    AppendText(passage+"\n");
    if(!code||readCode){Items.Add(passage);spans.Add((start,passage.Length));}
    // Preserve common inline emphasis without passing Markdown/HTML to a browser.
    if(!code)foreach(Match match in Regex.Matches(line,@"\*\*(.+?)\*\*|__(.+?)__"))
    {
     string text=match.Groups[1].Success?match.Groups[1].Value:match.Groups[2].Value;
     int offset=passage.IndexOf(text,StringComparison.Ordinal);if(offset<0)continue;
     Select(start+offset,text.Length);using var bold=new Font(font,FontStyle.Bold);SelectionFont=bold;
    }
   }
  }
  Select(0,0);ScrollToCaret();
 }
 public int SelectedIndex
 {
  get=>selected;
  set
  {
   if(selected>=0&&selected<spans.Count){var old=spans[selected];Select(old.Start,old.Length);SelectionBackColor=SystemColors.Window;}
   selected=value;
   if(value>=0&&value<spans.Count){var span=spans[value];Select(span.Start,span.Length);SelectionBackColor=SystemInformation.HighContrast?SystemColors.Highlight:Color.FromArgb(221,234,255);ScrollToCaret();}
  }
 }
 public int IndexFromPoint(Point point)
 {
  int character=GetCharIndexFromPosition(point);
  return spans.FindIndex(span=>character>=span.Start&&character<span.Start+span.Length);
 }
}
