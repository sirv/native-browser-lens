import assert from 'node:assert/strict';
import test from 'node:test';
import { Collector } from '../src/collector.js';
import { WebRequestEvidence } from '../src/portable.js';
import { originPattern } from '../src/permissions.js';

test('Firefox portless browser grants preserve exact project origins in the collector',()=>{
 assert.equal(originPattern('http://localhost:3000',true),'http://localhost/*');
 assert.equal(originPattern('http://localhost:3000',false),'http://localhost:3000/*');
 assert.equal(originPattern('http://[::1]:3000',true),'http://[::1]/*');
});

const profile={id:'project',name:'Project',origins:['https://fixture.test'],enabled:true,repositoryPath:'',documentationPaths:[],logPaths:[],ownership:[],adapter:'generic' as const,recording:'diagnostics' as const};
test('portable collection scopes pending requests to the original document and states its coverage',()=>{
 const collector=new Collector();collector.configure([profile]);collector.track({id:1,windowId:1,url:'https://fixture.test',active:true},'doc1');collector.mode(1,'limited');
 const events:any[]=[];let paused=false;
 const network=new WebRequestEvidence(collector,(tabId,kind,data,documentId)=>events.push({tabId,kind,data,documentId}),()=>{},()=>paused);
 network.event('request',{tabId:1,requestId:'one',url:'https://fixture.test/api',method:'GET',type:'xmlhttprequest'});
 network.event('response',{tabId:1,requestId:'one',url:'https://fixture.test/api',statusCode:503,responseHeaders:[{name:'Authorization',value:'secret'}]});
 assert.equal(events.length,2);assert.equal(events[1].data.status,503);assert.equal(events[1].data.source,'webRequest');
 collector.navigate(1,'doc2','https://fixture.test/next');collector.mode(1,'limited');
 network.event('network-complete',{tabId:1,requestId:'one',url:'https://fixture.test/api'});
 assert.equal(events.length,2,'Late completion must not enter the next document');
 paused=true;network.event('request',{tabId:1,requestId:'two',url:'https://fixture.test/api'});assert.equal(events.length,2);
 assert.deepEqual(collector.status(1)?.capabilities,['network-metadata','dom','storage','selected-tab-screenshot','page-actions']);
});

test('portable pending work is bounded and cannot survive removal or a pause',()=>{
 const collector=new Collector();collector.configure([profile]);collector.track({id:1,windowId:1,url:'https://fixture.test',active:true},'doc1');collector.mode(1,'limited');
 const events:any[]=[];const gaps:any[]=[];let paused=false;
 const network=new WebRequestEvidence(collector,(_tab,kind,data)=>events.push({kind,data}),(...gap)=>gaps.push(gap),()=>paused);
 for(let i=0;i<300;i++)network.event('request',{tabId:1,requestId:String(i),url:'https://fixture.test/api'});
 assert.ok(network.pending.size<=256);assert.ok(gaps.some(g=>g[1]==='network'));
 network.clear(1);assert.equal(network.pending.size,0);
 network.event('network-complete',{tabId:1,requestId:'299',url:'https://fixture.test/api'});assert.equal(events.length,300);
});
