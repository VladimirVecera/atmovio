"""Non-destructive Studio trim: validation, persistence and FFmpeg input boundaries."""
import os, sys, tempfile, shutil, io
from pathlib import Path
from unittest.mock import patch, Mock
base=Path(tempfile.mkdtemp(prefix='atmovio-trim-'))
os.environ['ATMOVIO_DIR']=str(base);os.environ['ATMOVIO_ADMIN_PASSWORD']='fixture-password'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
try:
 a.db_init();cfg=a.load_config()
 for start,end in [(-1,20),(20,10),(10,10),(0,101),(float('nan'),20),(0,float('inf'))]:
  try:a.studio_trim_bounds(100,start,end)
  except ValueError:pass
  else:raise AssertionError((start,end))
 assert a.studio_trim_bounds(100,0,None)==(0,100)
 src=base/'source.mp4';src.write_bytes(b'original')
 eid=a.record_export(cfg,'source',None,'west','Fixture',0,1000)
 ex=a._studio_export(cfg,eid)
 with patch.object(a,'studio_kick'):
  sid=a.studio_enqueue(cfg,ex,20,False,'','','Title','Description',trim_start=100,trim_end=500)
 with a.db() as con:job=dict(con.execute('SELECT * FROM studio_videos WHERE id=?',(sid,)).fetchone())
 assert (job['trim_start'],job['trim_end'])==(100,500)
 a.db_init()
 with a.db() as con:assert con.execute('SELECT trim_end FROM studio_videos WHERE id=?',(sid,)).fetchone()[0]==500
 commands=[]
 def popen(cmd,**kwargs):
  commands.append(cmd);Path(cmd[-1]).write_bytes(b'x'*2000)
  return Mock(stdout=io.StringIO(''),stderr=io.StringIO(''),returncode=0,poll=lambda:0)
 with patch.object(a,'storage_ready',return_value=True),patch.object(a,'frigate_exports',return_value={'source':{'video_path':str(src)}}),patch.object(a,'frigate_media_path',return_value=src),patch.object(a,'ffprobe_info',return_value={'duration':1000,'width':1920,'height':1080}),patch.object(a,'studio_out_dir',return_value=base),patch.object(a.subprocess,'Popen',side_effect=popen),patch.object(a,'run'),patch.object(a,'studio_after_render'):
  a.studio_render(cfg,job)
 cmd=commands[0];input_args=cmd[:cmd.index('-i')]
 assert input_args[input_args.index('-ss')+1]=='100.0'
 assert input_args[input_args.index('-t')+1]=='400.0'
 assert cmd[cmd.index('-filter_complex')+1].startswith('[0:v]setpts=(PTS-STARTPTS)/20')
 assert cmd[cmd.index('-movflags')+3]=='20.000'
 assert src.read_bytes()==b'original'
 print('PASS: invalid ranges, legacy full range, trim persistence/restart, FFmpeg seek/duration/reset, output duration, source unchanged')
finally:shutil.rmtree(base)
