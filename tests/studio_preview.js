/* Exercise the actual Studio preview components, with deterministic media engines. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const components = {}, events = {}, gains = [], animations = [];
let contexts = 0, closed = 0;
class AudioEngine {
  constructor(){contexts++;this.state='suspended';this.destination={};}
  createGain(){const node={gain:{value:1},connect(){},disconnect(){}};gains.push(node);return node;}
  createMediaElementSource(){return {connect(){},disconnect(){}};}
  async resume(){this.state='running';}
  async close(){closed++;}
}
let pendingPreview, previewBody;
const window = {AudioContext:AudioEngine,addEventListener(){}};
vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../src/atmovio/static/atmovio.js'),'utf8'),{
  FormData:class extends FormData{constructor(form){super();if(form)form.forEach(([key,value])=>this.append(key,value));}},fetch:(_url,options)=>new Promise(resolve=>{previewBody=options.body;pendingPreview=resolve;}),
  document:{readyState:'loading',addEventListener:(name,fn)=>events[name]=fn}, window,
  Alpine:{data:(name,factory)=>components[name]=factory}
});
events['alpine:init']();
(async()=>{
  const media={duration:180,currentTime:0,volume:1,paused:true,muted:true,pause(){this.paused=true;},async play(){this.paused=false;}};
  const music=components.musicPreview(.8),watchers={};
  music.$refs={track:media,offset:{value:'120'}};
  music.$watch=(name,fn)=>watchers[name]=fn;music.init();
  await music.playSelection();
  assert.equal(media.currentTime,120);assert.equal(media.paused,false);assert.equal(media.muted,false);
  assert.equal(gains[0].gain.value,.8);assert.equal(media.volume,1);
  music.level=2;music.applyVolume();assert.equal(gains[0].gain.value*media.volume,2);
  music.level=0;music.applyVolume();assert.equal(gains[0].gain.value,0);
  music.level=.45;music.applyVolume();assert.equal(gains[0].gain.value,.45);
  media.volume=.6;music.nativeVolumeChanged();assert.equal(music.level,.6);assert.equal(gains[0].gain.value,.6);
  music.$refs.offset.value=999;music.seekStart();assert.equal(media.currentTime,180);
  watchers.music();assert.equal(media.paused,true);
  await music.playSelection();assert.equal(contexts,1); // same media element must not be connected twice
  music.destroy();assert.equal(closed,1);
  window.AudioContext=undefined;
  const fallback=components.musicPreview(2);fallback.$refs=music.$refs;
  await fallback.playSelection();assert.match(fallback.audioMessage,/100 %/);assert.equal(media.paused,true);
  fallback.level=.5;await fallback.playSelection();assert.equal(media.volume,.5);assert.equal(media.paused,false);
  const effect=components.effectPreview('share',5,4);
  effect.$refs={caption:{animate(frames,options){const animation={frames,options,canceled:false,cancel(){this.canceled=true;}};animations.push(animation);return animation;}}};
  effect.playEffect(20);assert.equal(effect.playing,true);assert.equal(animations[0].options.duration,4000);
  assert.equal(animations[0].frames[1].offset,.3/4);assert.equal(effect.caption,'Sdílejte tento okamžik');
  effect.playEffect(7);assert.equal(animations[0].canceled,true);assert.equal(animations[1].options.duration,2000);
  animations[1].onfinish();assert.equal(effect.playing,false);assert.match(effect.effectMessage,/dokončena/);
  effect.at=99;effect.playEffect(.2);assert.equal(animations[2].options.duration,200);assert.ok(animations[2].frames[1].opacity<1);
  effect.stopEffect();assert.equal(animations[2].canceled,true);assert.equal(animations[2].onfinish,null);
  effect.effect='';effect.playEffect(10);assert.equal(animations.length,3);
  effect.effect='both';effect.playEffect(0);assert.match(effect.effectMessage,/délku/);
  effect.destroy();
  const uploaded=components.effectPreview('video',99,4,{vid:1,asset:'clip.mp4',items:[{asset:'clip.mp4',duration:5}],timing:'auto'});
  assert.equal(uploaded.effectTime(60),'0:15');assert.equal(uploaded.effectTime(3),'0:00');
  uploaded.timing='manual';assert.equal(uploaded.effectTime(10),'0:05');
  let plays=0;
  uploaded.$refs={effectVideo:{pause(){},async play(){plays++;},currentTime:0}};
  uploaded.$el={closest:()=>({querySelector:()=>({value:'fixture-csrf'})})};uploaded.$nextTick=async()=>{};
  let request=uploaded.playVideoEffect();uploaded.stopEffect();
  pendingPreview({ok:true,json:async()=>({url:'/stale.mp4'})});await request;
  assert.equal(plays,0);assert.equal(uploaded.previewUrl,'');assert.equal(uploaded.busy,false);
  request=uploaded.playVideoEffect();pendingPreview({ok:true,json:async()=>({url:'/ready.mp4'})});await request;
  assert.equal(plays,1);assert.equal(uploaded.previewUrl,'/ready.mp4');
  uploaded.resetVideoPreview();assert.equal(uploaded.previewUrl,'');
  uploaded.items=[{asset:'clip.mp4',duration:5,width:640,height:360,background:'none',crop:[0,0,1,1]}];
  uploaded.frameWidth=1280;uploaded.frameHeight=720;
  uploaded.posX=0;uploaded.posY=0;uploaded.positionChanged();
  let box=uploaded.positionBox();assert.ok(box.x>0&&box.y>0);assert.equal(uploaded.positioning,true);
  uploaded.posX=100;uploaded.posY=100;box=uploaded.positionBox();
  assert.ok(box.x+box.width<box.W&&box.y+box.height<box.H);
  uploaded.$refs.positionStage={getBoundingClientRect:()=>({width:640,height:360})};
  const target={focus(){},setPointerCapture(){},hasPointerCapture(){return true;},releasePointerCapture(){}};
  uploaded.beginDrag({button:0,pointerId:1,clientX:500,clientY:300,currentTarget:target});
  uploaded.moveDrag({pointerId:2,clientX:0,clientY:0});assert.equal(uploaded.posX,100);
  uploaded.moveDrag({pointerId:1,clientX:-500,clientY:-300});assert.equal(uploaded.posX,0);assert.equal(uploaded.posY,0);
  uploaded.endDrag({pointerId:1,currentTarget:target});assert.equal(uploaded.drag,null);
  uploaded.moveKey({key:'ArrowRight',shiftKey:true,preventDefault(){}});assert.equal(uploaded.posX,10);
  uploaded.moveKey({key:'ArrowDown',shiftKey:false,preventDefault(){}});assert.equal(uploaded.posY,1);
  request=uploaded.playVideoEffect();assert.equal(previewBody.get('x'),'10');assert.equal(previewBody.get('y'),'1');
  uploaded.positionChanged();pendingPreview({ok:true,json:async()=>({url:'/wrong-position.mp4'})});await request;
  assert.equal(uploaded.previewUrl,'');assert.equal(uploaded.positioning,true);
  const preferences=components.studioPreferences(true,false,false);
  preferences.$el={closest:selector=>{assert.equal(selector,'form');return [['csrf_token','fixture'],['speed','50'],['effect_x','25']];}};
  request=preferences.saveDefaults();assert.equal(previewBody.get('speed'),'50');assert.equal(preferences.defaultsBusy,true);
  pendingPreview({ok:true,json:async()=>({saved:true,message:'Saved'})});await request;
  assert.equal(preferences.defaultsSaved,true);assert.equal(preferences.defaultsMessage,'Saved');assert.equal(preferences.defaultsBusy,false);
  request=preferences.saveDefaults(true);assert.equal(previewBody.get('reset'),'1');
  pendingPreview({ok:true,json:async()=>({saved:false,message:'Reset'})});await request;assert.equal(preferences.defaultsSaved,false);
  request=preferences.saveDefaults();pendingPreview({ok:false,json:async()=>({error:'Unavailable effect'})});await request;
  assert.equal(preferences.defaultsSaved,false);assert.equal(preferences.defaultsMessage,'Unavailable effect');
  uploaded.$dispatch=()=>{};uploaded.asset='clip.mp4';
  request=uploaded.manageLibrary('delete','clip.mp4');assert.equal(previewBody.get('asset'),'clip.mp4');
  pendingPreview({ok:true,json:async()=>({items:[],trash:[{asset:'clip.mp4'}],message:'Moved'})});await request;
  assert.equal(uploaded.asset,'');assert.equal(uploaded.trash.length,1);assert.equal(uploaded.busy,false);
  request=uploaded.manageLibrary('restore','clip.mp4');pendingPreview({ok:true,json:async()=>({items:[{asset:'clip.mp4'}],trash:[],message:'Restored'})});await request;
  assert.equal(uploaded.items.length,1);assert.equal(uploaded.trash.length,0);
  console.log('Studio preview: gain, seek, replay, fallback, fade and cleanup OK');
})().catch(error=>{console.error(error);process.exitCode=1;});
