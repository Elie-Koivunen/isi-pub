isi job policies create --name=CUSTOM_low_Office_Hours \
--impact=medium --begin 'monday 00:01' --end 'monday 07:30' \
--impact=low --begin 'monday 07:30' --end 'monday 19:00' \
--impact=medium --begin 'monday 19:00' --end 'tuesday 00:01' \
\
--impact=medium --begin 'tuesday 00:01' --end 'tuesday 07:30' \
--impact=low --begin 'tuesday 07:30' --end 'tuesday 19:00' \
--impact=medium --begin 'tuesday 19:00' --end 'wednesday 00:01' \
\
--impact=medium --begin 'wednesday 00:01' --end 'wednesday 07:30' \
--impact=low --begin 'wednesday 07:30' --end 'wednesday 19:00' \
--impact=medium --begin 'wednesday 19:00' --end 'thursday 00:01' \
\
--impact=medium --begin 'thursday 00:01' --end 'thursday 07:30' \
--impact=low --begin 'thursday 07:30' --end 'thursday 19:00' \
--impact=medium --begin 'thursday 19:00' --end 'friday 00:01' \
\
--impact=medium --begin 'friday 00:01' --end 'friday 07:30' \
--impact=low --begin 'friday 07:30' --end 'friday 19:00' \
--impact=medium --begin 'friday 19:00' --end 'monday 00:01' 


isi job types modify --id=Collect --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=AutoBalance --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=AutoBalanceLin --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=Flexprotect --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=Flexprotectlin --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=smartpools --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=quotascan --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=mediascan --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=integrityscan --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=filepolicy --policy=CUSTOM_low_Office_Hours --force
isi job types modify --id=indexupdate --policy=CUSTOM_low_Office_Hours --force
