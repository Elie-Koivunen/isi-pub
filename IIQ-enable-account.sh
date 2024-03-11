isi auth users modify insightiq --enabled=true --password=Password123! --unlock 
isi job jobs start FSAnalyze --policy=MEDIUM --priority=4


onefs +9.5

isi auth users reset-password insightiq --zone=system --provider=lsa-file-provider:System
isi auth users modify insightiq --zone=system --provider=lsa-file-provider:System --enabled=true
