#!/usr/bin/env python3
"""Build all public targets from one committed tree. Credentials stay in env."""
import argparse,hashlib,json,os,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
VERSION='0.2.4-public.1';TAG='v'+VERSION
TARGETS={'macOS':('LTravel-'+VERSION+'-macOS-universal.app','macOS'),
 'macOS Workshop':('LTravel-Workshop-'+VERSION+'-macOS-universal.app','macOS'),
 'Windows':('LTravel-'+VERSION+'-Windows-x86_64.exe','Windows'),
 'Windows Workshop':('LTravel-Workshop-'+VERSION+'-Windows-x86_64.exe','Windows'),
 'Android':('LTravel-'+VERSION+'-Android-arm64-v8a.apk','Android'),
 'Android Workshop':('LTravel-Workshop-'+VERSION+'-Android-arm64-v8a.apk','Android')}
def run(args,**kw):return subprocess.run(args,cwd=ROOT,check=True,**kw)
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--godot',default=os.getenv('GODOT','godot'));ap.add_argument('--out',type=pathlib.Path,default=ROOT/'builds/public');ap.add_argument('--target',action='append',choices=list(TARGETS));args=ap.parse_args()
 commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
 if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip():raise SystemExit('Commit or stash source changes first; release builds require a clean tree.')
 if not subprocess.check_output([args.godot,'--version'],text=True).startswith('4.7.1.'):raise SystemExit('Godot 4.7.1 stable required')
 out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
 (ROOT/'BUILD_INFO.json').write_text(json.dumps({'version':VERSION,'tag':TAG,'commit':commit,'rules':'owner configuration required','baseline':'accepted workshop 0.2.4-r2 assembly'},indent=2)+'\n')
 run([args.godot,'--headless','--editor','--path',str(ROOT),'--import','--quit'],stdout=(out/'import.log').open('w'),stderr=subprocess.STDOUT)
 rows=[]
 for target in args.target or list(TARGETS):
  name,platform=TARGETS[target];dest=out/platform/name;dest.parent.mkdir(exist_ok=True)
  if platform=='Android':
   for key in ['GODOT_ANDROID_KEYSTORE_RELEASE_PATH','GODOT_ANDROID_KEYSTORE_RELEASE_USER','GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD']:
    if not os.getenv(key):raise SystemExit('Set Android release keystore environment variables locally; never commit them.')
  log=out/(target.replace(' ','-')+'.log')
  with log.open('w')as f:run([args.godot,'--headless','--path',str(ROOT),'--export-release',target,str(dest)],stdout=f,stderr=subprocess.STDOUT)
  if not dest.exists():raise SystemExit('Missing export: '+name)
  rows.append({'target':target,'file':str(dest.relative_to(out))})
 (out/'build-manifest.json').write_text(json.dumps({'version':VERSION,'tag':TAG,'commit':commit,'targets':rows},indent=2)+'\n')
 print('Exports complete:',commit,len(rows),'targets; see logs before publishing.')
if __name__=='__main__':main()
