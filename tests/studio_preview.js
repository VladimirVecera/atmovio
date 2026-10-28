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
let pendingPreview;
const window = {AudioContext:AudioEngine,addEventListener(){}};
vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../src/atmovio/static/atmovio.js'),'utf8'),{
  FormData,fetch:()=>new Promise(resolve=>{pendingPreview=resolve;}),
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
  console.log('Studio preview: gain, seek, replay, fallback, fade and cleanup OK');
})().catch(error=>{console.error(error);process.exitCode=1;});
