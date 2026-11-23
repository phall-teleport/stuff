import Foundation
import Testing
@testable import ServerLife

/// tests/kubegraph.test.mjs — a Helm release's manifest as a graph and as Mermaid.
@Suite struct KubeGraphTests {
    static let manifest = """

    ---
    # Source: web/templates/sa.yaml
    apiVersion: v1
    kind: ServiceAccount
    metadata: { name: web }
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata: { name: web-config }
    ---
    apiVersion: v1
    kind: Service
    metadata: { name: web }
    spec: { selector: { app: web } }
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata: { name: web }
    spec:
      rules:
        - http: { paths: [ { path: /, backend: { service: { name: web, port: { number: 80 } } } } ] }
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: web }
    spec:
      selector: { matchLabels: { app: web } }
      template:
        metadata: { labels: { app: web } }
        spec:
          serviceAccountName: web
          volumes: [ { name: c, configMap: { name: web-config } } ]
          containers:
            - name: web
              envFrom: [ { secretRef: { name: preexisting } } ]
    ---
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    metadata: { name: web }
    spec: { scaleTargetRef: { kind: Deployment, name: web } }

    """

    static func has(_ g: KubeGraph.Graph, _ from: String, _ to: String, _ label: String) -> Bool {
        g.edges.contains { $0.from == from && $0.to == to && $0.label == label }
    }

    @Test func referencesBetweenResources() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(Self.manifest))
        #expect(g.nodes.count == 6)
        #expect(Self.has(g, "Ingress/web", "Service/web", "routes"))
        #expect(Self.has(g, "Service/web", "Deployment/web", "selects"))
        #expect(Self.has(g, "Deployment/web", "ConfigMap/web-config", "mounts"))
        #expect(Self.has(g, "Deployment/web", "ServiceAccount/web", "runs as"))
        #expect(Self.has(g, "HorizontalPodAutoscaler/web", "Deployment/web", "scales"))
        #expect(g.edges.count == 5)
    }

    @Test func externalReferencesListed() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(Self.manifest))
        #expect(g.external == ["Secret/preexisting"])
        #expect(!g.edges.contains { $0.to == "Secret/preexisting" })
    }

    @Test func mermaid() {
        let m = KubeGraph.manifestGraph(Self.manifest, title: "Helm release web (default)").mermaid
        #expect(m.hasPrefix("---\ntitle: Helm release web (default)\n---\nflowchart LR\n"))
        #expect(m.contains("n_Ingress_web[\"Ingress<br/><b>web</b>\"]"))
        #expect(m.contains("n_Ingress_web -->|routes| n_Service_web"))
        #expect(m.contains("n_Deployment_web -->|runs as| n_ServiceAccount_web"))
        #expect(m.contains("classDef workload "))
    }

    @Test func ranks() {
        let r = ["Ingress", "Service", "Deployment", "ConfigMap", "RoleBinding", "ClusterRole"].map(KubeGraph.rankOf)
        #expect(r == r.sorted())
        #expect(KubeGraph.rankOf("SomeCustomThing") == 6)
    }

    @Test func emptyOrBroken() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(""))
        #expect(g.nodes.isEmpty && g.edges.isEmpty && g.external.isEmpty)
        _ = KubeGraph.manifestGraph(": : not yaml [")
    }

    static let more = """

    apiVersion: v1
    kind: Service
    metadata: { name: db-headless, labels: { app: db } }
    spec: { clusterIP: None, selector: { app: db }, ports: [ { port: 5432 } ] }
    ---
    apiVersion: apps/v1
    kind: StatefulSet
    metadata: { name: db }
    spec:
      replicas: 3
      serviceName: db-headless
      selector: { matchLabels: { app: db } }
      template:
        metadata: { labels: { app: db } }
        spec:
          imagePullSecrets: [ { name: regcred } ]
          containers: [ { name: pg, image: docker.io/library/postgres:16 } ]
      volumeClaimTemplates:
        - metadata: { name: data }
          spec: { storageClassName: gp3, resources: { requests: { storage: 10Gi } } }
    ---
    apiVersion: v1
    kind: Secret
    metadata: { name: regcred }
    type: kubernetes.io/dockerconfigjson
    ---
    apiVersion: v1
    kind: Secret
    metadata: { name: web-tls }
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata: { name: web }
    spec:
      tls: [ { secretName: web-tls, hosts: [ web.example.com ] } ]
      rules: [ { host: web.example.com, http: { paths: [ { path: /, backend: { service: { name: db-headless, port: { number: 5432 } } } } ] } } ]
    ---
    apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata: { name: gw }
    ---
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata: { name: r }
    spec:
      parentRefs: [ { name: gw } ]
      rules: [ { backendRefs: [ { name: db-headless, port: 5432 } ] } ]
    ---
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata: { name: db }
    spec: { selector: { matchLabels: { app: db } } }

    """

    @Test func statefulSet() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(Self.more))
        #expect(Self.has(g, "StatefulSet/db", "Service/db-headless", "governed by"))
        #expect(Self.has(g, "StatefulSet/db", "PersistentVolumeClaim/data-db-*", "claims"))
        #expect(Self.has(g, "StatefulSet/db", "Secret/regcred", "pulls with"))
        #expect(Self.has(g, "Service/db-headless", "StatefulSet/db", "selects"))
        #expect(g.nodes.first { $0.id == "PersistentVolumeClaim/data-db-*" }?.detail == "per replica · 10Gi · gp3")
        #expect(g.external.contains("StorageClass/gp3"))
    }

    @Test func tlsGatewayMonitor() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(Self.more))
        #expect(Self.has(g, "Ingress/web", "Secret/web-tls", "TLS"))
        #expect(Self.has(g, "HTTPRoute/r", "Service/db-headless", "routes"))
        #expect(Self.has(g, "HTTPRoute/r", "Gateway/gw", "attached to"))
        #expect(Self.has(g, "ServiceMonitor/db", "Service/db-headless", "scrapes"))
    }

    @Test func details() {
        let g = KubeGraph.buildGraph(KubeGraph.parseManifests(Self.more))
        let d = { (id: String) in g.nodes.first { $0.id == id }?.detail }
        #expect(d("StatefulSet/db") == "3× postgres:16")
        #expect(d("Service/db-headless") == "headless 5432")
        #expect(d("Ingress/web") == "web.example.com")
        #expect(KubeGraph.toMermaid(g).contains("StatefulSet<br/><b>db</b><br/><small>3× postgres:16</small>"))
    }
}
