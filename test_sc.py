import urllib.request
import urllib.parse
import json
import sys

try:
    with open('/var/lib/radiod/soundcloud_cid') as f:
        cid = f.read().split()[1]
except Exception as e:
    cid = 'KKzJxmw11tYpCs6T24P4uUYhqmjalG6M'

url = f'https://api-v2.soundcloud.com/tracks/1802461656?client_id=' + cid
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
resp = urllib.request.urlopen(req)
d = json.loads(resp.read().decode())
permalink = d.get('permalink_url')
print('Track permalink:', permalink)

# Now test resolve on this permalink
res_url = f'https://api-v2.soundcloud.com/resolve?url=' + urllib.parse.quote(permalink, safe="") + '&client_id=' + cid
req2 = urllib.request.Request(res_url, headers={'User-Agent': 'Mozilla/5.0'})
resp2 = urllib.request.urlopen(req2)
d2 = json.loads(resp2.read().decode())
print('Resolved kind:', d2.get('kind'), 'id:', d2.get('id'), 'title:', d2.get('title'))
