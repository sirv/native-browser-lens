import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).parents[1]))
from evidence import console_rows,network_rows


def event(kind,time,session='',**data):
    return dict(id=f'{kind}-{time}-{session}',projectId='p',tabId=1,documentId='d',kind=kind,timestamp=time,data=dict(sessionId=session,requestId='1',**data))


class EvidenceTests(unittest.TestCase):
    def test_target_scopes_and_redirect_hops_never_mix(self):
        events=[event('request',1000,'a',url='https://a.test',method='GET',monotonicTime=10),event('request',1010,'b',url='https://b.test',method='POST',monotonicTime=20),event('response',1020,'b',status=503),event('request',1030,'a',url='https://a.test/redirect',method='GET',monotonicTime=10.03,redirectResponse={'status':302}),event('network-complete',1050,'b',monotonicTime=20.04),event('response',1060,'a',status=200)]
        rows=network_rows(events)
        a,b,c=rows
        self.assertEqual([row['status'] for row in rows],[302,503,200])
        self.assertAlmostEqual(a['durationMs'],30)
        self.assertAlmostEqual(b['durationMs'],40)
        self.assertIsNone(c['durationMs'])
        self.assertEqual(len(b['events']),3)
        for item in events:item['data']['targetSession']=item['data'].pop('sessionId')
        self.assertEqual([row['status'] for row in network_rows(events)],[302,503,200])
        for item in events:item['data']['sessionId']='[REDACTED]';item['data'].pop('targetSession')
        self.assertTrue(all(len(row['events'])==1 for row in network_rows(events)))

    def test_missing_start_or_completion_stays_explicit(self):
        rows=network_rows([event('response',2000,status=404),event('response-body',2100,body='not an inferred request')])
        self.assertFalse(rows[0]['hasStart'])
        self.assertIsNone(rows[0]['durationMs'])
        self.assertEqual(rows[0]['method'],'—')

    def test_har_duration_and_console_severity_filter(self):
        har=event('devtools-network',1000,url='https://a.test',method='GET',status=200,durationMs=25,startedDateTime='1970-01-01T00:00:00.900Z')
        self.assertEqual(network_rows([har])[0]['durationMs'],25)
        events=[event('console',1,type='warn',args=[{'value':'stale cache'}]),event('exception',2,details={'text':'TypeError'})]
        self.assertEqual(console_rows(events,query='CACHE')[0]['severity'],'warning')
        self.assertEqual(len(console_rows(events,severity='error')),1)
        self.assertEqual(console_rows(events,severity='info'),[])
