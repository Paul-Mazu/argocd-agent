# ArgoCD Agent — konfiguracja Resource Proxy (POC)

## Architektura — jak to działa razem

```
Spoke Cluster (agent-int EKS)          Hub Cluster (ArgoCD EKS)
┌──────────────────────────┐           ┌────────────────────────────────────┐
│  argocd-agent            │           │  ArgoCD Server / Repo Server       │
│  (application-controller)│           │                                    │
│                          │           │  Principal                         │
│  Kubernetes API (prywat.)│   gRPC    │    ├─ gRPC server (:8443)          │
│                          │◄──────────┤    ├─ Redis Proxy (:6379)          │
│                          │  agent    │    └─ Resource Proxy (:9090)       │
└──────────────────────────┘  łączy    └────────────────────────────────────┘
                               się do
                               huba
```

### Dlaczego połączenie jest odwrócone?

Klastry spoke mają **prywatne endpointy** Kubernetes API — nie są dostępne z zewnątrz.
Standardowy ArgoCD łączy się bezpośrednio z API klastra, co tutaj jest niemożliwe.
Rozwiązanie: agent **na spoke klastrze** inicjuje wychodzące połączenie gRPC do principala na hub klastrze.
Hub cluster ma ALB z publicznym endpointem — agent może się do niego połączyć.

### Po co Resource Proxy?

ArgoCD Server (na hub klastrze) musi czasem odpytać Kubernetes API zdalnego klastra — np.:

- przy tworzeniu aplikacji w UI (sprawdza `/version` i dostępne API resources)
- przy przeglądaniu "live manifest" (pobiera aktualny stan zasobów)

Ponieważ API klastra spoke jest prywatne, Resource Proxy działa jako pośrednik:

```
ArgoCD Server ──HTTPS+mTLS──► Resource Proxy (:9090) ──gRPC stream──► Agent ──► Kubernetes API
```

1. ArgoCD myśli, że łączy się z normalnym Kubernetes API
2. Resource Proxy identyfikuje agenta z CN certyfikatu klienta
3. Przekazuje request przez istniejące połączenie gRPC do agenta
4. Agent wykonuje prawdziwe zapytanie do lokalnego Kubernetes API
5. Odpowiedź wraca tą samą drogą

---

## Co zrobiliśmy krok po kroku

### Błąd 1: `unsupported protocol scheme "argocd-agent"`

**Komunikat:** `Get "argocd-agent://agent-int/version?timeout=32s": unsupported protocol scheme "argocd-agent"`

**Przyczyna:** Cluster secret w ArgoCD miał `server: argocd-agent://agent-int` — własny schemat URL
który Go HTTP client nie rozumie. To był format z wcześniejszej (przestarzałej) wersji argocd-agent.

**Naprawa:** Zmiana `server` w cluster secret na właściwy adres Resource Proxy:

```
https://argocd-agent-principal-principal-resource-proxy:9090?agentName=agent-int
```

**Dlaczego taki URL?**

- `argocd-agent-principal-principal-resource-proxy` — nazwa Kubernetes Service (znaleziona przez `kubectl get svc -n argocd`)
- `:9090` — port Resource Proxy
- `?agentName=agent-int` — parametr informujący, który agent jest docelowy (historyczny, okazuje się że proxy go nie używa — patrz niżej)

---

### Błąd 2: `dial tcp: lookup argocd-agent-principal-resource-proxy on ...: no such host`

**Przyczyna:** Użyliśmy złej nazwy serwisu. Helm chart dodaje prefix release name do nazw serwisów.

**Diagnoza:**

```bash
kubectl get svc -n argocd | grep -i "resource-proxy\|9090"
# Wynik: argocd-agent-principal-principal-resource-proxy
```

**Naprawa:** Poprawna nazwa serwisu to `argocd-agent-principal-principal-resource-proxy` (z podwójnym "principal" bo release name = "argocd-agent-principal").

---

### Błąd 3: `x509: certificate is not valid for any names`

**Przyczyna:** Certyfikat TLS Resource Proxy nie miał SAN (Subject Alternative Name) pasującego
do nazwy serwisu `argocd-agent-principal-principal-resource-proxy`.

**Naprawa tymczasowa:** Dodanie `insecure: true` w config cluster secret — pomija weryfikację certyfikatu serwera.
To akceptowalne jako POC wewnątrz klastra (komunikacja wewnątrzklastrowa).

---

### Błąd 4: `tls: certificate required`

**Przyczyna:** Resource Proxy wymaga **mTLS** — client musiał przedstawić certyfikat klienta.
Konfiguracja `insecure: true` bez certyfikatu klienta nie wystarczy.

**Diagnoza:** Resource Proxy ma `ClientAuth: tls.RequireAndVerifyClientCert` — sprawdza certyfikat klienta
przy każdym połączeniu. Bez niego odrzuca request.

**Naprawa:** Wygenerowanie certyfikatów przez openssl w cloud shell.

#### Dlaczego secret `argocd-agent-ca` nie miał klucza prywatnego?

Principal był uruchomiony z `jwtAllowGenerate: "true"` — generuje klucze jednorazowo w pamięci,
nie zapisuje klucza prywatnego CA do sekretu. Stąd `argocd-agent-ca` miał tylko `ca.crt` (bez `tls.key`).
Rozwiązanie: ręczna regeneracja CA przez openssl.

#### Kroki generowania certyfikatów (w cloud shell):

```bash
# 1. Nowe CA z kluczem prywatnym
kubectl delete secret argocd-agent-ca -n argocd
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=argocd-agent-resource-proxy" -out ca.crt
kubectl create secret generic argocd-agent-ca -n argocd \
  --from-file=ca.crt=ca.crt --from-file=tls.crt=ca.crt --from-file=tls.key=ca.key

# 2. Certyfikat Resource Proxy z prawidłowymi SANs
kubectl delete secret argocd-agent-resource-proxy-tls -n argocd
openssl genrsa -out proxy.key 4096
cat > proxy-ext.cnf <<EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
[req_dn]
CN = argocd-agent-principal-principal-resource-proxy
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = argocd-agent-principal-principal-resource-proxy
DNS.2 = argocd-agent-principal-principal-resource-proxy.argocd
DNS.3 = argocd-agent-principal-principal-resource-proxy.argocd.svc
DNS.4 = argocd-agent-principal-principal-resource-proxy.argocd.svc.cluster.local
EOF
openssl req -new -key proxy.key \
  -subj "/CN=argocd-agent-principal-principal-resource-proxy" \
  -out proxy.csr -config proxy-ext.cnf
openssl x509 -req -in proxy.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out proxy.crt -days 365 -sha256 \
  -extensions v3_req -extfile proxy-ext.cnf
kubectl create secret tls argocd-agent-resource-proxy-tls -n argocd \
  --cert=proxy.crt --key=proxy.key

# 3. Certyfikat klienta — CN musi być nazwą agenta (patrz niżej!)
openssl genrsa -out client.key 4096
openssl req -new -key client.key -subj "/CN=agent-int" -out client.csr
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365 -sha256

# 4. Restart principala
kubectl rollout restart deployment argocd-agent-principal-principal -n argocd
```

---

### Błąd 5: `failed to discover server resources, zero resources returned`

**Przyczyna:** mTLS działało, ale Resource Proxy zwracał pusty wynik. Logi principala pokazały:

```
Successfully authenticated via TLS client certificate CN" agent=argocd-server
```

**Kluczowe odkrycie:** Resource Proxy **ignoruje** parametr `?agentName=` z URL.
Zamiast tego wyciąga nazwę agenta z **CN certyfikatu klienta**:

```go
// principal/resource.go
if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
    cert := r.TLS.PeerCertificates[0]
    agentName := cert.Subject.CommonName  // ← CN z certyfikatu = nazwa agenta
    return agentName, nil
}
```

Certyfikat miał `CN=argocd-server` → proxy szukało agenta o nazwie `argocd-server` → brak takiego agenta → puste zasoby.

**Naprawa:** Regeneracja certyfikatu klienta z `CN=agent-int` (linia w kroku 3 powyżej).

---

### Finalna konfiguracja cluster secret

```typescript
const agentIntClusterSecret = appCluster.addManifest("AgentIntClusterSecret", {
  apiVersion: "v1",
  kind: "Secret",
  metadata: {
    name: "agent-int-cluster",
    namespace: argocdNamespaceName,
    labels: {
      "argocd.argoproj.io/secret-type": "cluster",
      "argocd-agent.argoproj.io/secret-type": "cluster",
      "argocd-agent.argoproj-labs.io/agent-name": "agent-int",
    },
  },
  type: "Opaque",
  stringData: {
    name: "agent-int",
    server:
      "https://argocd-agent-principal-principal-resource-proxy:9090?agentName=agent-int",
    config: JSON.stringify({
      tlsClientConfig: {
        insecure: true, // Pomija weryfikację cert serwera (POC)
        certData: "<BASE64>", // client.crt z CN=agent-int
        keyData: "<BASE64>", // client.key
        caData: "<BASE64>", // ca.crt
      },
    }),
  },
});
```

**Dlaczego `insecure: true`?** Certyfikat Resource Proxy może nie mieć SAN pasującego do nazwy serwisu.
Po regeneracji certów z poprawnymi SANs (krok 2 powyżej) można to zmienić na `false` + dodać `caData`.

---

## Co zrobić w produkcji (po POC)

1. **Zastąpić ALB przez NLB z TLS passthrough** dla połączenia agent → principal (gRPC).
   ALB terminuje mTLS co uniemożliwia self-registration i komplikuje certyfikaty.

2. **Włączyć self-registration** — principal automatycznie tworzy cluster secret z poprawnymi certyfikatami
   i JWT tokenem przy każdym połączeniu agenta:

   ```typescript
   enableSelfClusterRegistration: "true",
   selfRegistrationClientCertSecret: "argocd-agent-resource-proxy-tls",
   ```

   Wymaga dodania tych wartości do Helm chart principala (v0.2.0 jeszcze nie wspiera).

3. **Przechowywać certyfikaty w AWS Secrets Manager** zamiast hardkodować base64 w CDK.

4. **Rotacja certyfikatów** — skrypt lub Job w Kubernetes do automatycznej odnowy certyfikatów klienta.

5. **Zmienić auth z userpass na mtls** — userpass jest oznaczony jako deprecated w argocd-agent.
   Po przejściu na NLB passthrough: `auth: "mtls:CN=([^,]+)"` na principalu.

Usuniecie Idling app

```bash
kubectl get applications -n argocd

kubectl patch application otel -n argocd \
  --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel
  namespace: agent-int
spec:
  project: default
  source:
    repoURL: https://github.com/FSS-System/Otel-Demo
    path: charts/otel-demo
    targetRevision: argo-preparation
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: "https://argocd-agent-principal-principal-resource-proxy:9090?agentName=agent-int"
    namespace: agent-int
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel
  namespace: agent-int
spec:
  project: default
  source:
    repoURL: https://github.com/POC-System/Otel-Demo
    path: charts/otel-demo
    targetRevision: argo-preparation
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: "https://argocd-agent-principal-principal-resource-proxy:9090?agentName=agent-int"
    namespace: agent-int
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```