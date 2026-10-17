"""Read-only views of captured evidence; missing timing and channels stay explicit."""
from datetime import datetime
import json
import math


def number(value):
    return value if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) else None


def console_rows(events,query='',severity='all'):
    rows=[]
    for event in events:
        if event.get('kind') not in ('console','exception'):continue
        data=event.get('data',{});entry=data.get('entry',{});details=data.get('details',{})
        entry=entry if isinstance(entry,dict) else {};details=details if isinstance(details,dict) else {}
        level='error' if event['kind']=='exception' else str(data.get('type') or entry.get('level') or 'info')
        level='warning' if level in ('warn','warning') else 'error' if level in ('error','assert') else 'info'
        message=entry.get('text') or details.get('text') or ' '.join(str(arg.get('value',arg.get('description',arg.get('type','')))) for arg in data.get('args',[]) if isinstance(arg,dict))
        message=str(message or json.dumps(data,ensure_ascii=False))
        if severity not in ('all',level) or query.casefold() not in message.casefold():continue
        rows.append(dict(event=event,severity=level,text=message,timestamp=number(event.get('timestamp')) or 0))
    return rows


def network_rows(events,query=''):
    rows=[];latest={}
    kinds={'request','response','network-failure','network-complete','response-body','cache','devtools-network'}
    for event in events:
        kind=event.get('kind')
        if kind not in kinds:continue
        data=event.get('data',{});timestamp=number(event.get('timestamp')) or 0
        scope=(event.get('projectId'),event.get('tabId'),event.get('documentId'))
        request=str(data.get('requestId',event.get('id','')))
        session=data.get('targetSession',data.get('sessionId'))
        unknown=session is not None and (not isinstance(session,str) or session.lower()=='[redacted]')
        key=(*scope,'unresolved-'+str(event.get('id')) if unknown else session or '',request)
        if session is None and kind!='request':
            matches=[value for candidate,value in latest.items() if candidate[:3]==scope and candidate[-1]==request and not candidate[-2].startswith('unresolved-')]
            if len(matches)==1:key=matches[0]['key']
            elif len(matches)>1:key=(*scope,'unresolved-'+str(event.get('id')),request)
        row=latest.get(key)
        if kind in ('request','devtools-network') or row is None:
            if row is not None and kind=='request' and isinstance(data.get('redirectResponse'),dict):
                row['status']=number(data['redirectResponse'].get('status'))
                end=number(data.get('monotonicTime'))
                if end is not None and row['monotonicStart'] is not None and end>=row['monotonicStart']:row['durationMs']=(end-row['monotonicStart'])*1000
                row['redirect']=True
            start=timestamp
            if kind=='devtools-network' and isinstance(data.get('startedDateTime'),str):
                try:start=datetime.fromisoformat(data['startedDateTime'].replace('Z','+00:00')).timestamp()*1000
                except ValueError:pass
            row=dict(key=key,start=start,hasStart=kind in ('request','devtools-network'),method=data.get('method') or '—',url=data.get('url') or 'Request URL unavailable',status=None,durationMs=None,monotonicStart=number(data.get('monotonicTime')) if kind=='request' else None,events=[],failed=False,cached=False,redirect=False)
            rows.append(row);latest[key]=row
        row['events'].append(event)
        if data.get('url'):row['url']=data['url']
        if number(data.get('status')) is not None:row['status']=number(data['status'])
        if kind=='network-failure':row['failed']=True
        if kind=='cache' or data.get('fromDiskCache') or data.get('fromServiceWorker') or data.get('fromCache'):row['cached']=True
        if kind in ('network-complete','network-failure'):
            end=number(data.get('monotonicTime'))
            if end is not None and row['monotonicStart'] is not None and end>=row['monotonicStart']:row['durationMs']=(end-row['monotonicStart'])*1000
        if kind=='devtools-network':
            duration=number(data.get('durationMs'))
            if duration is not None and duration>=0:row['durationMs']=duration
    return sorted([row for row in rows if query.casefold() in (str(row['method'])+' '+str(row['url'])+' '+str(row['status'])).casefold()],key=lambda row:row['start'])


import gi
gi.require_version('Gtk','4.0')
from gi.repository import Gtk,Pango


class EvidenceBrowser(Gtk.Box):
    def __init__(self,raw,load_timeline=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL,spacing=8)
        self.capture=None;self.raw=raw;self.load_timeline=load_timeline;self.timeline=[];self.timeline_findings={};self.timeline_capture=None
        controls=Gtk.Box(spacing=6)
        self.mode=Gtk.DropDown.new_from_strings(['Console','Network','Raw','Timeline'])
        self.mode.connect('notify::selected',lambda *_:self.render())
        self.query=Gtk.SearchEntry(placeholder_text='Filter captured evidence',hexpand=True)
        self.query.connect('search-changed',lambda *_:self.render())
        self.severity=Gtk.DropDown.new_from_strings(['All levels','Errors','Warnings','Info'])
        self.severity.connect('notify::selected',lambda *_:self.render())
        for widget in (self.mode,self.query,self.severity):controls.append(widget)
        self.append(controls)
        self.coverage=Gtk.Expander(label='Coverage gaps')
        self.gaps=Gtk.Label(xalign=0,wrap=True,selectable=True)
        self.coverage.set_child(self.gaps);self.append(self.coverage)
        self.summary=Gtk.Label(xalign=0,wrap=True,css_classes=['dim-label']);self.append(self.summary)
        self.list=Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.list.connect('row-selected',self.selected)
        list_scroll=Gtk.ScrolledWindow(child=self.list,hexpand=True,vexpand=True)
        self.detail=Gtk.TextView(editable=False,monospace=True,wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.detail.set_left_margin(10);self.detail.set_right_margin(10)
        split=Gtk.Paned(orientation=Gtk.Orientation.VERTICAL,position=180,vexpand=True)
        split.set_start_child(list_scroll);split.set_end_child(Gtk.ScrolledWindow(child=self.detail,vexpand=True))
        self.stack=Gtk.Stack(vexpand=True);self.stack.add_named(split,'rows');self.stack.add_named(Gtk.ScrolledWindow(child=raw,vexpand=True),'raw')
        self.append(self.stack)
        self.render()

    def set_capture(self,capture):
        previous=self.capture;self.capture=capture
        if previous is not None and capture is not None and all(previous.get(key)==capture.get(key) for key in ('id','events','gaps')):return
        self.render()

    def loaded_timeline(self,identity,result):
        if (self.capture or {}).get('id')!=identity:return
        self.timeline=result.get('timeline',[]);self.timeline_capture=identity
        self.timeline_findings={'finding:'+finding['id']:finding for finding in result.get('timelineFindings',[])}
        if 'error' in result:self.summary.set_text(result['error'])
        else:self.render()

    def selected(self,_,row):
        self.detail.get_buffer().set_text(json.dumps(row.evidence,indent=2,ensure_ascii=False) if row else 'Select captured evidence to inspect its fields, headers, body or stack.')

    def render(self):
        if not hasattr(self,'list'):return
        network=self.mode.get_selected()==1;raw=self.mode.get_selected()==2;timeline=self.mode.get_selected()==3
        self.severity.set_visible(not network and not raw and not timeline);self.query.set_visible(not raw)
        self.stack.set_visible_child_name('raw' if raw else 'rows')
        capture=self.capture or {};events=capture.get('events',[])
        gaps=capture.get('gaps',[])
        self.coverage.set_label(f'Coverage gaps ({len(gaps)})');self.gaps.set_text('\n\n'.join(gap['channel']+': '+gap['reason'] for gap in gaps) or 'No additional gaps were reported. This does not establish complete collection.')
        child=self.list.get_first_child()
        while child:
            following=child.get_next_sibling();self.list.remove(child);child=following
        self.selected(None,None)
        if raw:self.summary.set_text('Raw saved capture, including explicit channel omissions.');return
        if timeline:
            identity=capture.get('id')
            if identity and identity!=self.timeline_capture and self.load_timeline:
                self.timeline_capture=identity;self.timeline=[]
                self.summary.set_text('Reading recorded relationships…')
                self.load_timeline(identity,lambda result:self.loaded_timeline(identity,result));return
            self.summary.set_text('Request/trace links use recorded identifiers. Nearby events are temporal context only. Select a row for its linked artifacts and exact evidence.')
            rows={row['event']['id']:row for row in self.timeline} if identity else {}
            for item in rows.values():
                event=item['event']
                if self.query.get_text().casefold() not in json.dumps(item,ensure_ascii=False).casefold():continue
                row=Gtk.ListBoxRow();content=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=4)
                offset=(event['timestamp']-capture.get('identity',{}).get('capturedAt',event['timestamp']))/1000
                detail=str(event.get('data',{}).get('status') or '')+' '+str(event.get('data',{}).get('url') or event['id'])
                label=f"{offset:+.3f}s  {event['kind']}  {detail.strip()}"
                content.append(Gtk.Label(label=label,xalign=0,ellipsize=Pango.EllipsizeMode.END,max_width_chars=50))
                if item['failure']:content.add_css_class('error')
                for link in item['links']:
                    content.append(Gtk.Label(label=link['relationship']+' → '+link['target'],xalign=0,ellipsize=Pango.EllipsizeMode.END,max_width_chars=50,css_classes=['dim-label']))
                row.evidence={**item,'linkedArtifacts':[dict(link,event=rows.get(link['target'],{}).get('event'),finding=self.timeline_findings.get(link['target'])) for link in item['links']]}
                row.set_child(content);self.list.append(row)
            return
        rows=network_rows(events,self.query.get_text()) if network else console_rows(events,self.query.get_text(),['all','error','warning','info'][self.severity.get_selected()])
        self.summary.set_text(f'{len(rows)} captured requests. Bars use recorded request timing; dotted markers have no measured completion.' if network else f'{len(rows)} captured console entries. Missing console coverage is listed above.')
        start=min((row['start'] for row in rows),default=0) if network else 0
        end=max((row['start']+(row['durationMs'] or 0) for row in rows),default=start+1) if network else 1
        span=max(1,end-start)
        for item in rows:
            row=Gtk.ListBoxRow();content=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=5)
            for edge in ('top','bottom','start','end'):getattr(content,'set_margin_'+edge)(8)
            if network:
                status=f"{item['status']:g}" if item['status'] is not None else 'failed' if item['failed'] else 'no status'
                title=f"{item['method']}  {status}  {item['url']}"
                duration=f"{item['durationMs']:.1f} ms" if item['durationMs'] is not None else 'completion timing unavailable'
                suffix=(' · cached' if item['cached'] else '')+(' · redirect' if item['redirect'] else '')+(' · request start missing' if not item['hasStart'] else '')
                content.append(Gtk.Label(label=duration+suffix,xalign=0,css_classes=['dim-label']))
                bar=Gtk.DrawingArea(content_height=10,hexpand=True)
                def draw(widget,cr,width,height,item=item):
                    found,color=widget.get_style_context().lookup_color('accent_color')
                    cr.set_source_rgba(color.red,color.green,color.blue,1) if found else cr.set_source_rgb(.48,.64,.97)
                    x=max(0,min(width-2,(item['start']-start)/span*width))
                    if item['durationMs'] is None:
                        cr.set_dash([2,2]);cr.set_line_width(2);cr.move_to(x,1);cr.line_to(x,height-1);cr.stroke()
                    else:cr.rectangle(x,2,max(2,min(width-x,item['durationMs']/span*width)),height-4);cr.fill()
                bar.set_draw_func(draw);content.append(bar)
                row.evidence={'requestStartRecorded':item['hasStart'],'durationMs':item['durationMs'],'events':item['events']}
                css='error' if item['failed'] or (item['status'] is not None and item['status']>=400) else None
            else:
                title=item['severity'].upper()+'  '+item['text'];row.evidence=item['event'];css=item['severity'] if item['severity'] in ('error','warning') else None
            label=Gtk.Label(label=title,xalign=0,ellipsize=Pango.EllipsizeMode.END,max_width_chars=50)
            label.set_tooltip_text(title)
            if css:label.add_css_class(css)
            content.prepend(label);row.set_child(content);self.list.append(row)
