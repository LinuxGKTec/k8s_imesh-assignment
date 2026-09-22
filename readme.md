
## 1. Overview & Architecture

This repository contains the manifests, Infra setup, and incident post-mortem for a 3-tier Kubernetes application flow. The scenario demonstrates a network connectivity failure between the `frontend` and `backend` workloads, followed by a structured troubleshooting approach to identify and resolve the issue.

### Application Architecture

`[ client Pod ] ──(HTTP)──> [ frontend-svc ] ──(HTTP)──> [ backend-svc ] ──> [ backend Pod ]`


* Client: Interactive pod used to initiate client-side traffic (`curlimages/curl`).
* Frontend: NGINX application serving web traffic and routing requests (`nginx:alpine`).
* Backend: Lightweight HTTP echo service returning static payload (`hashicorp/http-echo`).



## 2. Prerequisites & Environment Setup

### Prerequisites
* Docker
* kind (Kubernetes in Docker)
* kubectl

Step 1: Create Kind Cluster

Create a multi-node cluster using the bash script kind_up.sh that i have wrriten under Kind_Infra folder. Script kind_up.sh run based on kind-cluster.yaml menifest file.

`cd Kind_Infra`
`bash kind-up.sh`

`Mac:IMesh_Assignment gautamkumar$ kind get clusters`
`imesh-tech`


Step 2: Deploy Workloads & Services

Apply all application manifests into the default namespace:

`kubectl apply -f Menifest/deployment.yaml`
`kubectl apply -f Menifest/service.yaml`


Verify that all pods reach `Running` state:

`kubectl get pods -o wide`

Step 3: Verify Baseline Health

Before injecting the fault, verify baseline connectivity across all tiers:

1. Verify Client -> Frontend
`kubectl exec client -- curl -s http://frontend-svc`
```bash
Mac:IMesh_Assignment gautamkumar$ kubectl exec client -- curl -s http://frontend-svc
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, nginx is successfully installed and working.
Further configuration is required for the web server, reverse proxy, 
API gateway, load balancer, content cache, or other features.</p>

<p>For online documentation and support please refer to
<a href="https://nginx.org/">nginx.org</a>.<br/>
To engage with the community please visit
<a href="https://community.nginx.org/">community.nginx.org</a>.<br/>
For enterprise grade support, professional services, additional 
security features and capabilities please refer to
<a href="https://f5.com/nginx">f5.com/nginx</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
```

2. Verify Frontend -> Backend
``` bash
Mac:Kubernates gautamkumar$ kubectl exec  deployment/frontend -- curl -v -s http://backend-svc
* Host backend-svc:80 was resolved.
* IPv6: (none)
* IPv4: 10.96.67.151
*   Trying 10.96.67.151:80...
* connect to 10.96.67.151 port 80 from 10.244.1.4 port 37502 failed: Connection refused
* Failed to connect to backend-svc:80 after 14 ms: Could not connect to server
* closing connection #0
command terminated with exit code 7
```


So we can see frontend can not communicate with backend.

3. Troubleshooting to find the root case of this issue.

To find the root cause i will start investigation from pod level.
# Phase 1: Pod Status & Workload Health

``` bash
Mac:Kubernates gautamkumar$ kubectl  get pods -o wide
NAME                       READY   STATUS    RESTARTS        AGE    IP           NODE                NOMINATED NODE   READINESS GATES
backend-565c56b855-6rb6j   1/1     Running   0               139m   10.244.1.5   imesh-tech-worker   <none>           <none>
client                     1/1     Running   1 (8m53s ago)   139m   10.244.1.6   imesh-tech-worker   <none>           <none>
frontend-576fbd7c-bsz8f    1/1     Running   0               139m   10.244.1.4   imesh-tech-worker   <none>           <none>
```

All pods are `Running` with valid pod IPs. Outage is not caused by a crashed container or pod crash-loop.

# Phase 2. DNS & Service Discovery
Verify if `frontend` can resolve the internal `backend-svc` domain via CoreDNS.
```
Mac:Kubernates gautamkumar$ kubectl  get svc -o wide
NAME           TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE     SELECTOR
backend-svc    ClusterIP   10.96.67.151   <none>        80/TCP         139m    app=backend
frontend-svc   NodePort    10.96.1.135    <none>        80:30080/TCP   139m    app=frontend
kubernetes     ClusterIP   10.96.0.1      <none>        443/TCP        4h10m   <none>
```

```
kubectl exec deployment/frontend -- nslookup backend-svc

Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	backend-svc.default.svc.cluster.local
Address: 10.96.67.151
```

DNS resolution is operating correctly. `backend-svc` resolves to ClusterIP `10.96.67.151`.

# Phase 3. Service Endpoints Check

Verify if the service selector is correctly discovering backing pods and registering endpoints
```
Mac:Kubernates gautamkumar$ kubectl get endpoints
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME           ENDPOINTS         AGE
backend-svc    10.244.1.5:8081   141m
frontend-svc   10.244.1.4:80     141m
kubernetes     172.18.0.2:6443   4h12m

```

Endpoint exists (`10.244.1.5`), confirming service label selectors match pod label but I can see that backend-svc endpoint is pointing to wrong targetport 8081. Same we can verify by describring the service with following command.

# Phase 4: Service Definition Inspection
Inspect the full spec details for `backend-svc`.


kubectl describe svc backend-svc 

Name:              backend-svc
Namespace:         default
Labels:            <none>
Annotations:       <none>
Selector:          app=backend
Type:              ClusterIP
IP Family Policy:  SingleStack
IP Families:       IPv4
IP:                10.96.67.151
IPs:               10.96.67.151
Port:              <unset>  80/TCP
TargetPort:        8081/TCP
Endpoints:         10.244.1.5:8081
Session Affinity:  None
Events:            <none>

The service is configured to forward incoming port `80` traffic to `targetPort: 8081`. However, `backend` application process is listening on `8080`. 


### **Root Cause**
The `backend-svc` Service specification contained an incorrect `targetPort` configuration (`8081` instead of `8080`). 



### ***Resolutions***:
To fix this issue we need to correct targetport in backend-svc and this i can do it in multiple way for example by rereating backend svc with coorect target port or by patching backend-svc  svc with correct target port.


Mac:Kubernates gautamkumar$ kubectl patch svc backend-svc --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8080}]'
service/backend-svc patched

At this point issue has been fixed and frontend and backend sarted communicating.


Mac:Kubernates gautamkumar$ kubectl exec  deployment/frontend -- curl  -s http://backend-svc
hello from backend


### ***Verification**

#### Step 1: Verify Endpoint Port Mapping

Mac:Kubernates gautamkumar$ kubectl get endpoints backend-svc 
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME          ENDPOINTS         AGE
backend-svc   10.244.1.5:8080   3h8m


#### Step 2: Verify Internal Service Communication (`frontend` -> `backend-svc`)

kubectl exec deployment/frontend -- curl -s http://backend-svc
hello from backend

#### Step 3: End-to-End Client Flow Verification (`client` -> `frontend` -> `backend`)
kubectl exec client -- curl -s http://frontend-svc

<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, nginx is successfully installed and working.
Further configuration is required for the web server, reverse proxy, 
API gateway, load balancer, content cache, or other features.</p>

<p>For online documentation and support please refer to
<a href="https://nginx.org/">nginx.org</a>.<br/>
To engage with the community please visit
<a href="https://community.nginx.org/">community.nginx.org</a>.<br/>
For enterprise grade support, professional services, additional 
security features and capabilities please refer to
<a href="https://f5.com/nginx">f5.com/nginx</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>


## ***Repository Layout**

.
├── Kind_Infra
│   ├── kind-cluster.yaml
│   └── kind-up.sh
├── Menifest
│   ├── deployment.yaml
│   └── service.yaml
└── readme.md