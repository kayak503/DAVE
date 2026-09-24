namespace LocalVoice;

internal static class WindowsTheme
{
 public static Color Surface => SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(247,248,250);
 public static Color Ink => SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(34,37,47);
 public static Color Accent => SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(104,85,218);
 public static Color Rail => SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(27,29,39);
 public static void Apply(Control root)
 {
  root.BackColor=root is SettingsCard or SettingRow || root.Parent is SettingsCard or SettingRow || Equals(root.Tag,"paper") ? SystemColors.Window : Surface;root.ForeColor=Ink;
  foreach(Control control in root.Controls)
  {
   Apply(control);
   if(control is Button button)
   {
    button.UseVisualStyleBackColor=false;button.FlatStyle=FlatStyle.Flat;button.FlatAppearance.BorderSize=0;
    button.Padding=new Padding(12,6,12,6);button.MinimumSize=new Size(72,36);
    button.AutoSize=true;button.AutoSizeMode=AutoSizeMode.GrowAndShrink;button.Margin=new Padding(0,0,8,6);
   }
   if(control is TextBoxBase or ListBox or ComboBox or NumericUpDown)control.BackColor=SystemColors.Window;
   if(control is ComboBox combo)combo.FlatStyle=FlatStyle.Flat;
   if(control is DataGridView grid)
   {
    grid.EnableHeadersVisualStyles=false;grid.BackgroundColor=SystemColors.Window;grid.GridColor=Color.FromArgb(236,237,242);
    grid.ColumnHeadersDefaultCellStyle.BackColor=Surface;grid.ColumnHeadersDefaultCellStyle.ForeColor=Ink;
    grid.ColumnHeadersDefaultCellStyle.SelectionBackColor=Surface;grid.ColumnHeadersDefaultCellStyle.SelectionForeColor=Ink;
    grid.ColumnHeadersDefaultCellStyle.Padding=new Padding(10);grid.ColumnHeadersHeightSizeMode=DataGridViewColumnHeadersHeightSizeMode.AutoSize;
    grid.DefaultCellStyle.BackColor=SystemColors.Window;grid.DefaultCellStyle.ForeColor=Ink;
    grid.DefaultCellStyle.SelectionBackColor=Accent;grid.DefaultCellStyle.SelectionForeColor=SystemColors.HighlightText;
    grid.DefaultCellStyle.Padding=new Padding(10);grid.DefaultCellStyle.WrapMode=DataGridViewTriState.True;
    grid.AutoSizeRowsMode=DataGridViewAutoSizeRowsMode.DisplayedCells;grid.CellBorderStyle=DataGridViewCellBorderStyle.SingleHorizontal;
   }
  }
 }
}

internal sealed class WorkspaceNavigation:UserControl
{
 readonly FlowLayoutPanel navigation=new(){Dock=DockStyle.Fill,Padding=new Padding(12,28,12,12),FlowDirection=FlowDirection.TopDown,WrapContents=false};
 readonly Panel rail=new(){Dock=DockStyle.Left,Width=210};
 readonly Panel content=new(){Dock=DockStyle.Fill};
 readonly Label pageTitle=new(){Dock=DockStyle.Top,Height=48,Font=new Font("Segoe UI",19,FontStyle.Bold)};
 readonly Label pageSubtitle=new(){Dock=DockStyle.Fill,Font=new Font("Segoe UI",9)};
 readonly List<Panel> pages=new();readonly List<Button> buttons=new();int selected;
 public WorkspaceNavigation()
 {
  Dock=DockStyle.Fill;Controls.Add(content);var header=new Panel{Dock=DockStyle.Top,Height=114,Padding=new Padding(28,20,24,8)};header.Controls.Add(pageSubtitle);header.Controls.Add(pageTitle);Controls.Add(header);Controls.Add(rail);
  rail.Controls.Add(navigation);rail.Controls.Add(new Label{Dock=DockStyle.Bottom,Height=64,Text="●  LOCAL & PRIVATE",Padding=new Padding(22,16,0,0),Font=new Font("Segoe UI",8)});
  navigation.Controls.Add(new Label{Text="dave",AutoSize=true,Font=new Font("Segoe UI",24,FontStyle.Bold),Margin=new Padding(12,0,0,2)});
  navigation.Controls.Add(new Label{Text="On-device voice",AutoSize=true,Font=new Font("Segoe UI",8),Margin=new Padding(12,0,0,36)});
 }
 public Panel AddPage(string title)
 {
  int index=pages.Count;var page=new Panel{Dock=DockStyle.Fill,Padding=new Padding(28,0,24,24),Visible=index==0};pages.Add(page);content.Controls.Add(page);
  var button=new ModernButton{Navigation=true,IconIndex=index,Text=title,Width=150,Height=42,TextAlign=ContentAlignment.MiddleLeft,AccessibleName=title};
  button.Click+=(_,_)=>SelectedIndex=index;buttons.Add(button);navigation.Controls.Add(button);if(index==0)SelectedIndex=0;return page;
 }
 public int SelectedIndex
 {
  get=>selected;
  set{if(value<0||value>=pages.Count)return;selected=value;for(int i=0;i<pages.Count;i++)pages[i].Visible=i==value;pages[value].BringToFront();pageTitle.Text=new[]{"Reading room","Dictation","Transcription","Model library","Settings"}[value];pageSubtitle.Text=new[]{"Make time to listen.","Turn your thoughts into words.","Give every conversation a clear transcript.","A little intelligence. Entirely on your device.","Make Dave feel like you."}[value];RefreshSelection();}
 }
 public void RefreshSelection()
 {
  rail.BackColor=navigation.BackColor=WindowsTheme.Rail;
  foreach(Control c in rail.Controls){c.BackColor=WindowsTheme.Rail;c.ForeColor=Color.FromArgb(159,165,184);}
  foreach(Control c in navigation.Controls){c.BackColor=WindowsTheme.Rail;c.ForeColor=Color.FromArgb(211,214,226);}
  for(int i=0;i<buttons.Count;i++){var b=buttons[i];b.AutoSize=false;b.Height=(int)(36*DeviceDpi/96f);b.Width=navigation.ClientSize.Width-navigation.Padding.Horizontal;if(b is ModernButton modern){modern.Selected=i==selected;modern.Invalidate();}}
 }
}
