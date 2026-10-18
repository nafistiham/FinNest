"""Operator-only, read-only audit export. Tests use a fake client; evaluation never calls it."""
import argparse
from datetime import UTC,datetime
import json
from pathlib import Path


def _utc(value):
    result=value if isinstance(value,datetime) else datetime.fromisoformat(value.replace('Z','+00:00'))
    return result.replace(tzinfo=UTC) if result.tzinfo is None else result.astimezone(UTC)


def _json_default(value):
    if isinstance(value,datetime):
        return value.isoformat()
    raise TypeError(f'unsupported export value: {type(value).__name__}')


def export_audit(client,output: Path,since: str):
    cutoff=_utc(since)
    documents=[]
    for snapshot in client.collection('audit').where('kind','==','score').stream():
        row=snapshot.to_dict()
        if row.get('kind')!='score' or not row.get('at') or _utc(row['at'])<cutoff:
            continue
        documents.append(dict(row,id=row.get('id') or snapshot.id))
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(''.join(json.dumps(row,default=_json_default,allow_nan=False)+'\n' for row in documents),encoding='utf-8')
    return len(documents)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project',required=True)
    parser.add_argument('--since',required=True,help='ISO timestamp, UTC when no offset is present')
    parser.add_argument('--out',required=True,type=Path)
    args=parser.parse_args(argv)
    from google.cloud import firestore
    count=export_audit(firestore.Client(project=args.project),args.out,args.since)
    print(f'exported {count} score documents')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
