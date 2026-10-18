"""Opt-in MCP interoperability check using the installed Codex client and managed login."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

repo=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(repo/'linux'))
import onboarding

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--exports',type=Path,required=True);parser.add_argument('--runtime',type=Path,default=repo/'linux');parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,mode=0o700,exist_ok=True)
runtime=args.runtime.resolve();root=args.output.resolve()
wrapper=root/'server.py';audit=root/'requests.jsonl'
wrapper.write_text('import sys,json\nfrom pathlib import Path\nsys.path.insert(0,'+repr(str(runtime))+')\nimport mcp_server\noriginal=mcp_server.Server.handle\ndef record(self,value):\n if isinstance(value,dict):\n  with Path('+repr(str(audit))+').open("a") as output: output.write(json.dumps({"method":value.get("method"),"tool":value.get("params",{}).get("name")})+"\\n")\n return original(self,value)\nmcp_server.Server.handle=record\nmcp_server.main()\n')
command=[onboarding.codex_binary(),'-a','never','exec','--ignore-user-config','--ignore-rules','--ephemeral','--skip-git-repo-check','--json','-c','features.apps=false','-c','features.plugins=false','-c','features.hooks=false','-c','features.multi_agent=false','-c','project_doc_max_bytes=0','-c','mcp_servers.lens.command='+json.dumps(sys.executable),'-c','mcp_servers.lens.args='+json.dumps([str(wrapper),str(args.exports.resolve())]),'Use only the lens MCP tools. Call lens_list_reports, inspect its first report with lens_inspect, then query lens_verification for its first capture. Report the exact verification status and localRetest value. Do not use shell commands, edit files, or read any private notebook.']
if binary:=os.environ.get('LENS_EVIDENCE_BINARY'):command[-1:-1]=['-c','mcp_servers.lens.env.LENS_EVIDENCE_BINARY='+json.dumps(binary)]
environment={key:value for key,value in os.environ.items() if key not in ('OPENAI_API_KEY','CODEX_API_KEY')}
with (root/'client.jsonl').open('w') as output:result=subprocess.run(command,cwd=root,env=environment,stdout=output,stderr=subprocess.STDOUT,timeout=300)
assert result.returncode==0,'Inspect the private client log.'
requests=[json.loads(line) for line in audit.read_text().splitlines()]
methods={request['method'] for request in requests};tools={request['tool'] for request in requests if request['method']=='tools/call'}
assert {'initialize','notifications/initialized','tools/list','tools/call'}<=methods,methods
assert {'lens_list_reports','lens_inspect','lens_verification'}<=tools,tools
proof=dict(passed=True,actualCodexClient=True,stdioHandshake=True,toolsDiscovered=True,calledTools=sorted(tools),explicitExportsDirectory=str(args.exports.resolve()),privateNotebookRead=False)
(root/'result.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps(proof))
