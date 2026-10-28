/* Player behavior with a fake media element; no cameras or browser required. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const events = {}, components = {}, listeners = new Map();
let paused = 0, destroyed = 0;
const video = {currentTime:0, src:'', pause(){paused++;}, play(){return Promise.resolve();},
  removeAttribute(){this.src='';}, getAttribute(){return this.src;}, load(){}, canPlayType(){return 'probably';}};
const context = {document:{readyState:'loading',addEventListener:(name,fn)=>events[name]=fn},
  window:{addEventListener:(name,fn)=>listeners.set(name,fn),removeEventListener:name=>listeners.delete(name)},
  Alpine:{data:(name,fn)=>components[name]=fn}, URLSearchParams, AbortController, Date, Intl,
  location:{search:''}, setInterval:()=>1,clearInterval(){},setTimeout,clearTimeout,
  fetch:async()=>({ok:true,json:async()=>({day:'2026-10-28',start:1000,end:10000,tz:'Europe/Prague',spans:[[1000,5000],[5500,9000]]})})};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../src/atmovio/static/atmovio.js'),'utf8'),context);
events['alpine:init']();
(async()=>{
  const p=components.cameraPlayer('east');p.$refs={video};await p.init();
  assert.equal(video.src,'/stream/east/hls/master.m3u8');assert.equal(p.live,true);
  p.mark('from');assert.equal(p.from,null);
  p.seek(1500);video.onloadedmetadata();assert.equal(video.currentTime,30);assert.equal(p.live,false);
  assert.match(video.src,/1470\/5070\/master.m3u8$/);
  p.mark('from');p.seek(1600);video.onloadedmetadata();p.mark('to');
  assert.equal(p.validSelection(),true);assert.equal(p.from,1500);assert.equal(p.to,1600);
  const before=video.src;p.seek(5200);assert.equal(video.src,before);assert.match(p.message,/není záznam/);
  await p.previewSelection();video.onloadedmetadata();video.currentTime=130;p.tick();
  assert.equal(p.cursor,1600);assert.equal(p.stopAt,null);assert.ok(paused>0);
  p.seek(4990);p.nextSegment();assert.equal(p.cursor,8560.1);
  p.playSpans=[[1000,2000],[2500,3000]];assert.equal(p.mediaOffset(2600),1100);assert.equal(p.wallTime(1100),2600);
  p.from=1500;p.to=2600;p.spans=[[1000,2000],[2500,3000]];assert.equal(p.selectionHasGaps(),true);
  p.from=1500;p.to=1600;
  assert.equal(p.from,1500);assert.equal(p.to,1600);
  p.from=1000;p.to=22601;assert.equal(p.validSelection(),false);
  p.tz='Europe/Prague';assert.match(p.fullStamp(Date.parse('2026-10-28T05:37:42Z')/1000),/28\.\s?10\.\s?2026.*06:37:42/);
  const size={};p.$el={getBoundingClientRect:()=>({top:180}),style:{setProperty:(k,v)=>size[k]=v}};
  p.$refs.transport={offsetHeight:200};context.window.innerHeight=720;context.window.scrollY=0;p.fitPlayer();
  assert.equal(size['--player-height'],'322px');
  context.window.innerHeight=600;p.fitPlayer();assert.equal(size['--player-height'],'202px');
  p.$el.getBoundingClientRect=()=>({top:80});context.window.scrollY=100;p.fitPlayer();assert.equal(size['--player-height'],'202px');
  p.destroy();
  class FakeHls{static isSupported(){return true;}static Events={ERROR:'error'};loadSource(){}attachMedia(){}on(){}destroy(){destroyed++;}}
  context.Hls=context.window.Hls=FakeHls;
  const h=components.cameraPlayer('east');h.$refs={video};h.goLive();h.destroy();
  assert.equal(destroyed,1);assert.equal(listeners.has('keydown'),false);assert.equal(p.controller.signal.aborted,true);
  const editor=components.speedPreview('/source.mp4',20,100,10,40);
  editor.$refs={trimVideo:video};editor.$watch=()=>{};editor.init();editor.previewTrim();
  assert.equal(video.currentTime,10);assert.equal(video.playbackRate,1);
  video.currentTime=41;editor.boundPreview();editor.destroy();
  console.log('PASS: live/archive switch, wall-clock seeking, gaps, persistent OD/DO, bounded preview, HLS cleanup and request cancellation');
})().catch(error=>{console.error(error);process.exitCode=1;});
