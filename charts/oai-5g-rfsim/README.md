OAI 5G SA end-to-end with RF simulator (OAI orchestration case1) packaged for OpenShift + Argo CD.
Deploy from the O-RAN portal: Deploy applications -> chart charts/oai-5g-rfsim -> namespace oai.
Check: oc logs -n oai deploy/oai-nr-ue -c nr-ue | grep -i 'pdu session'  and  oc exec -n oai deploy/oai-nr-ue -- ping -I oaitun_ue1 -c3 12.1.1.1
