from datetime import UTC,datetime
import json
from types import SimpleNamespace

from export_audit import export_audit


def test_export_preserves_document_id_filters_scores_and_since_locally(tmp_path):
    class Collection:
        def where(self, field, op, value):
            assert (field,op,value)==('kind','==','score')
            return self
        def stream(self):
            rows=[('a',{'kind':'score','at':'2026-10-17T10:00:00Z'}),
                  ('b',{'kind':'score','at':datetime(2026,10,17,11,tzinfo=UTC)}),
                  ('old',{'kind':'score','at':'2026-10-16T00:00:00Z'}),
                  ('other',{'kind':'intervene','at':'2026-10-17T10:00:00Z'})]
            return [SimpleNamespace(id=aid,to_dict=lambda row=row:row) for aid,row in rows]
    class Client:
        def collection(self,name):
            assert name=='audit'
            return Collection()
    path=tmp_path/'audit.jsonl'
    assert export_audit(Client(),path,'2026-10-17T00:00:00Z')==2
    got=[json.loads(line) for line in path.read_text().splitlines()]
    assert [row['id'] for row in got]==['a','b']
    assert got[1]['at']=='2026-10-17T11:00:00+00:00'
