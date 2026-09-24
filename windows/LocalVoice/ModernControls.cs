using System.Drawing.Drawing2D;

namespace LocalVoice;

internal sealed class ModernButton:Button
{
 public void InvokeAction()=>OnClick(EventArgs.Empty);
 public int IconIndex{get;set;}=-1;
 public bool Emphasis{get;set;}
 public bool Navigation{get;set;}
 public bool Selected{get;set;}
 bool hovered,pressed;
 public ModernButton(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;}
 protected override void OnMouseEnter(EventArgs e){hovered=true;Invalidate();base.OnMouseEnter(e);}
 protected override void OnMouseLeave(EventArgs e){hovered=false;pressed=false;Invalidate();base.OnMouseLeave(e);}
 protected override void OnMouseDown(MouseEventArgs e){pressed=true;Invalidate();base.OnMouseDown(e);}
 protected override void OnMouseUp(MouseEventArgs e){pressed=false;Invalidate();base.OnMouseUp(e);}
 protected override void OnPaint(PaintEventArgs e)
 {
  bool active=Selected||Emphasis;
  Color background=active?WindowsTheme.Accent:Navigation?WindowsTheme.Rail:Color.White;
  if(SystemInformation.HighContrast)background=active?SystemColors.Highlight:SystemColors.ButtonFace;
  if(hovered&&!active)background=SystemInformation.HighContrast?SystemColors.ControlLight:Navigation?Color.FromArgb(47,49,64):Color.FromArgb(240,238,250);
  if(pressed)background=WindowsTheme.Accent;
  Color foreground=!Enabled?SystemColors.GrayText:active||pressed?(SystemInformation.HighContrast?SystemColors.HighlightText:Color.White):Navigation?Color.FromArgb(203,207,222):WindowsTheme.Ink;
  e.Graphics.Clear(Parent?.BackColor??WindowsTheme.Surface);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
  var bounds=new Rectangle(1,1,Width-3,Height-3);int radius=Math.Min(16,Height/2);
  using var path=new GraphicsPath();path.AddArc(bounds.Left,bounds.Top,radius,radius,180,90);path.AddArc(bounds.Right-radius,bounds.Top,radius,radius,270,90);path.AddArc(bounds.Right-radius,bounds.Bottom-radius,radius,radius,0,90);path.AddArc(bounds.Left,bounds.Bottom-radius,radius,radius,90,90);path.CloseFigure();
  using var brush=new SolidBrush(background);e.Graphics.FillPath(brush,path);
  if(!Navigation&&!active){using var border=new Pen(Color.FromArgb(219,225,233));e.Graphics.DrawPath(border,path);}
  var textBounds=Rectangle.Inflate(ClientRectangle,-14,-4);
  if(Navigation&&IconIndex>=0){float scale=DeviceDpi/96f;var iconBounds=new Rectangle((int)(14*scale),0,(int)(24*scale),Height);using var iconFont=new Font("Segoe MDL2 Assets",11);string[] icons={"\uE8F1","\uE720","\uE8A5","\uE7B8","\uE713"};TextRenderer.DrawText(e.Graphics,icons[IconIndex],iconFont,iconBounds,foreground,TextFormatFlags.VerticalCenter|TextFormatFlags.HorizontalCenter);textBounds.X+=(int)(32*scale);textBounds.Width-=(int)(32*scale);}
  TextRenderer.DrawText(e.Graphics,Text,Font,textBounds,foreground,TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine|TextFormatFlags.EndEllipsis|(Navigation?TextFormatFlags.Left:TextFormatFlags.HorizontalCenter));
  if(Focused&&ShowFocusCues){var focus=Rectangle.Inflate(ClientRectangle,-5,-5);ControlPaint.DrawFocusRectangle(e.Graphics,focus,foreground,background);}
 }
}

internal sealed class SettingsCard:TableLayoutPanel
{
 public SettingsCard(){ColumnCount=1;ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));AutoSize=true;AutoSizeMode=AutoSizeMode.GrowAndShrink;Padding=new Padding(20);Margin=new Padding(0,0,0,16);BackColor=Color.White;}
 public void Add(Control control){control.Dock=DockStyle.Top;control.Margin=new Padding(0,0,0,12);RowStyles.Add(new RowStyle(SizeType.AutoSize));Controls.Add(control,0,RowCount++);}
 protected override void OnLayout(LayoutEventArgs e){foreach(Control item in Controls)if(item is Label label){label.AutoSize=true;label.MaximumSize=new Size(Math.Max(80,ClientSize.Width-Padding.Horizontal),0);}base.OnLayout(e);}
 protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);using var pen=new Pen(Color.FromArgb(228,232,239));e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);}
}

internal sealed class SettingRow:TableLayoutPanel
{
 public SettingRow(string title,Control value)
 {
  Height=54;RowCount=1;RowStyles.Add(new RowStyle(SizeType.Percent,100));ColumnCount=2;ColumnStyles.Add(new ColumnStyle(SizeType.Percent,38));ColumnStyles.Add(new ColumnStyle(SizeType.Percent,62));AutoSize=false;AutoSizeMode=AutoSizeMode.GrowAndShrink;Margin=new Padding(0,0,0,12);Padding=new Padding(0,8,0,8);
  var label=new Label{Text=title,AutoSize=true,Anchor=AnchorStyles.Left,Margin=new Padding(0,0,12,0)};
  Controls.Add(label,0,0);value.Anchor=AnchorStyles.Left|AnchorStyles.Right;value.Margin=Padding.Empty;
  if(value is NumericUpDown){value.Anchor=AnchorStyles.Right;value.Width=80;}
  Controls.Add(value,1,0);
 }
}



