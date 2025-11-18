import json,collections,sys,os
p=os.path.join(os.path.dirname(__file__), 'output', 'drive_analysis.json')
if not os.path.exists(p):
    print('drive_analysis.json not found at', p); sys.exit(2)
with open(p,'r',encoding='utf-8') as f:
    items=json.load(f)

total=len(items)
with_hash=sum(1 for i in items if i.get('quickXorHash'))
with_label=sum(1 for i in items if i.get('sensitivityLabelName'))
labels=[i.get('sensitivityLabelName') for i in items if i.get('sensitivityLabelName')]
top=collections.Counter(labels).most_common(10)
print('total:', total)
print('with_quickXorHash:', with_hash)
print('with_sensitivityLabelName:', with_label)
print('\nTop labels:')
for k,v in top:
    print(f'{k}\t{v}')
