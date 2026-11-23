import Foundation
import Testing
@testable import ServerLife

/// tests/kubeprovider.test.mjs (+ the heartbeat states from kuberesources.js).
@Suite struct KubeProviderTests {
    typealias P = KubeProvider
    static func node(_ name: String, _ labels: JSON = [:], _ providerID: String = "", _ ready: Bool = true, _ kubelet: String = "v1.35.9") -> JSON {
        ["metadata": ["name": .string(name), "labels": labels], "spec": ["providerID": .string(providerID)],
         "status": ["conditions": [["type": "Ready", "status": ready ? "True" : "False"]], "nodeInfo": ["kubeletVersion": .string(kubelet)]]]
    }
    static func s(_ p: JSON?, _ k: String) -> String? { p?[k].stringish }

    @Test func kubeconfigEKS() {
        let p = P.fromKubeconfig(contextName: "arn:aws:eks:us-west-2:123456789012:cluster/shared", server: "https://ABC.gr7.us-west-2.eks.amazonaws.com")
        #expect(Self.s(p, "provider") == "eks")
        #expect(["region", "account", "clusterName", "how"].map { Self.s(p, $0) } == ["us-west-2", "123456789012", "shared", "kubeconfig"])
        let gov = P.fromKubeconfig(contextName: "fips", server: "https://99E7.yl4.us-gov-west-1.eks.amazonaws.com",
                                   exec: ["command": "aws", "args": ["--region", "us-gov-west-1", "eks", "get-token", "--cluster-name", "fips"]])
        #expect(["provider", "region", "clusterName"].map { Self.s(gov, $0) } == ["eks", "us-gov-west-1", "fips"])
        let ex = P.fromKubeconfig(contextName: "x", server: "https://10.0.0.1",
                                  exec: ["command": "/usr/local/bin/aws", "args": ["eks", "get-token", "--cluster-name=prod", "--region=eu-west-1"]])
        #expect(["provider", "region", "clusterName"].map { Self.s(ex, $0) } == ["eks", "eu-west-1", "prod"])
        #expect(Self.s(P.fromKubeconfig(contextName: "y", exec: ["command": "aws-iam-authenticator", "args": ["token", "-i", "old"]]), "clusterName") == "old")
    }

    @Test func kubeconfigOthers() {
        let g = P.fromKubeconfig(contextName: "gke_my-project-1_us-central1_web", server: "https://34.1.2.3")
        #expect(["provider", "project", "location", "clusterName"].map { Self.s(g, $0) } == ["gke", "my-project-1", "us-central1", "web"])
        #expect(Self.s(P.fromKubeconfig(contextName: "renamed", server: "https://34.1.2.3", exec: ["command": "gke-gcloud-auth-plugin"]), "provider") == "gke")
        let a = P.fromKubeconfig(contextName: "web-aks", clusterName: "web-aks", server: "https://web-aks-dns-abc123.hcp.eastus.azmk8s.io:443")
        #expect(["provider", "region"].map { Self.s(a, $0) } == ["aks", "eastus"])
        #expect(Self.s(P.fromKubeconfig(contextName: "z", server: "https://10.1.1.1", exec: ["command": "kubelogin", "args": ["get-token"]]), "provider") == "aks")
        #expect(Self.s(P.fromKubeconfig(contextName: "minikube"), "provider") == "minikube")
        #expect(Self.s(P.fromKubeconfig(contextName: "kind-dev"), "provider") == "kind")
        #expect(Self.s(P.fromKubeconfig(contextName: "docker-desktop"), "provider") == "docker-desktop")
        #expect(Self.s(P.fromKubeconfig(contextName: "k3d-lab"), "provider") == "k3s")
        #expect(P.fromKubeconfig(contextName: "teleport.example.com-dev", server: "https://teleport.example.com:443",
                                 exec: ["command": "tsh", "args": ["kube", "credentials"]]) == nil)
    }

    @Test func labelsAndNames() {
        #expect(Self.s(P.fromLabels(["teleport.dev/cloud": "AWS", "region": "us-east-1", "account-id": "123456789012"]), "account") == "123456789012")
        #expect(Self.s(P.fromLabels(["cloud": "aws", "location": "us-west-2"]), "region") == "us-west-2")
        #expect(Self.s(P.fromLabels(["aws/env": "dev"]), "provider") == "eks")
        #expect(Self.s(P.fromLabels(["cloud": "gcp"]), "provider") == "gke")
        #expect(Self.s(P.fromLabels(["azure/aks-managed-poolName": "agentpool"]), "provider") == "aks")
        #expect(P.fromLabels(["env": "demo", "owner": "me"]) == nil)
        let p = P.combine(P.fromName("prod-eks"))
        #expect(Self.s(p, "provider") == "eks" && Self.s(p, "how") == "name" && p?["guess"] == true)
        #expect(P.fromName("weeks") == nil)
    }

    @Test func fromCluster() {
        #expect(Self.s(P.fromCluster(version: "v1.35.9-eks-577a51e"), "provider") == "eks")
        #expect(Self.s(P.fromCluster(version: "v1.35.8-gke.1796000"), "provider") == "gke")
        let aks = P.fromCluster(nodes: [Self.node("a", ["kubernetes.azure.com/agentpool": "agentpool", "topology.kubernetes.io/region": "westus"],
            "azure:///subscriptions/x/resourceGroups/mc/providers/Microsoft.Compute/virtualMachineScaleSets/aks-agentpool/virtualMachines/0")], version: "v1.32.11")
        #expect(Self.s(aks, "provider") == "aks" && Self.s(aks, "region") == "westus")
        let kops = P.fromCluster(nodes: [Self.node("n", [:], "aws:///us-east-1a/i-0abc")], version: "v1.30.1")
        #expect(Self.s(kops, "provider") == "eks" && kops?["managed"] == false && Self.s(kops, "short") == "AWS")
        #expect(Self.s(P.fromCluster(nodes: [Self.node("m", ["minikube.k8s.io/name": "minikube"])]), "provider") == "minikube")
        #expect(Self.s(P.fromCluster(nodes: [Self.node("k", [:], "kind://docker/kind/kind-control-plane")]), "provider") == "kind")
    }

    @Test func combining() {
        let p = P.combine(P.fromName("prod-eks"), P.fromLabels(["cloud": "aws", "location": "us-west-2"]), P.fromCluster(version: "v1.35.9-eks-1"))
        #expect(["provider", "how", "region"].map { Self.s(p, $0) } == ["eks", "cluster", "us-west-2"])
        #expect(p?["guess"] == false)
        let manual: JSON = ["provider": "aks", "how": "manual", "short": "AKS", "subscription": "s1"]
        let m = P.combine(P.fromCluster(version: "v1.35.9-eks-1"), manual, P.fromLabels(["cloud": "azure", "resource-group": "rg1"]))
        #expect(["provider", "how", "subscription", "resourceGroup"].map { Self.s(m, $0) } == ["aks", "manual", "s1", "rg1"])
    }

    @Test func consoleLinks() {
        #expect(P.consoleUrl(["provider": "eks", "region": "us-west-2"], clusterName: "shared") == "https://console.aws.amazon.com/eks/home?region=us-west-2#/clusters/shared")
        #expect(P.consoleUrl(["provider": "eks", "region": "us-gov-west-1"], clusterName: "fips").hasPrefix("https://console.amazonaws-us-gov.com/"))
        #expect(P.consoleUrl(["provider": "gke", "project": "p1", "location": "us-central1"], clusterName: "web")
                == "https://console.cloud.google.com/kubernetes/clusters/details/us-central1/web/details?project=p1")
        #expect(P.consoleUrl(["provider": "aks", "subscription": "s", "resourceGroup": "rg"], clusterName: "web").hasSuffix("managedClusters/web/overview"))
        #expect(P.consoleUrl(["provider": "aks", "region": "eastus"], clusterName: "web") == "")
        #expect(P.consoleUrl(["provider": "eks", "region": "us-east-1", "managed": false], clusterName: "kops") == "")
    }

    @Test func pools() {
        let nodes = [
            Self.node("a", ["eks.amazonaws.com/nodegroup": "ng-1", "eks.amazonaws.com/capacityType": "ON_DEMAND", "node.kubernetes.io/instance-type": "t3.xlarge", "topology.kubernetes.io/zone": "us-west-2a"]),
            Self.node("b", ["eks.amazonaws.com/nodegroup": "ng-1", "eks.amazonaws.com/capacityType": "ON_DEMAND", "node.kubernetes.io/instance-type": "t3.xlarge", "topology.kubernetes.io/zone": "us-west-2b"], "", false),
            Self.node("c", ["karpenter.sh/nodepool": "spot", "karpenter.sh/capacity-type": "spot", "node.kubernetes.io/instance-type": "m7g.large"]),
            Self.node("d", ["eks.amazonaws.com/compute-type": "fargate"]),
        ]
        let pools = P.nodePools(nodes, "eks")
        let ng = pools.first { $0["name"].string == "ng-1" }!
        #expect(ng["kind"] == "nodegroup" && ng["nodes"] == 2 && ng["ready"] == 1 && ng["types"] == ["t3.xlarge"])
        #expect(ng["capacity"] == ["ON_DEMAND"] && ng["zones"] == ["us-west-2a", "us-west-2b"] && ng["selector"] == "eks.amazonaws.com/nodegroup=ng-1")
        #expect(pools.first { $0["kind"] == "karpenter" }?["selector"] == "karpenter.sh/nodepool=spot")
        #expect(pools.first { $0["kind"] == "fargate" }?["selector"] == "eks.amazonaws.com/compute-type=fargate")
        let g = P.nodePools([Self.node("g", ["cloud.google.com/gke-nodepool": "default-pool", "cloud.google.com/gke-spot": "true", "topology.kubernetes.io/zone": "us-central1-a"])], "gke")[0]
        #expect(g["name"] == "default-pool" && g["capacity"] == ["Spot"] && g["selector"] == "cloud.google.com/gke-nodepool=default-pool")
        let a = P.nodePools([Self.node("a", ["kubernetes.azure.com/agentpool": "agentpool", "kubernetes.azure.com/mode": "system", "topology.kubernetes.io/zone": "0"])], "aks")[0]
        #expect(a["name"] == "agentpool" && a["mode"] == "system" && a["capacity"] == ["Regular"] && a["zones"] == [])
    }

    @Test func identitiesAndAwsAuth() {
        func sa(_ ns: String, _ name: String, _ ann: JSON) -> JSON { ["metadata": ["namespace": .string(ns), "name": .string(name), "annotations": ann]] }
        let ids = P.cloudIdentities([
            sa("kube-system", "ebs", ["eks.amazonaws.com/role-arn": "arn:aws:iam::123456789012:role/ebs"]),
            sa("app", "web", ["iam.gke.io/gcp-service-account": "web@p.iam.gserviceaccount.com"]),
            sa("app", "api", ["azure.workload.identity/client-id": "00000000-0000-0000-0000-000000000000"]),
            sa("app", "plain", [:]),
        ])
        #expect(ids.map { "\($0["namespace"].string ?? "")/\($0["name"].string ?? "") \($0["cloud"].string ?? "") \($0["via"].string ?? "")" }
                == ["app/api aks Workload Identity", "app/web gke Workload Identity", "kube-system/ebs eks IRSA"])
        let maps = P.awsAuthMappings(["data": [
            "mapRoles": "- rolearn: arn:aws:iam::123456789012:role/nodes\n  username: system:node:{{EC2PrivateDNSName}}\n  groups: [system:bootstrappers, system:nodes]\n",
            "mapUsers": "- userarn: arn:aws:iam::123456789012:user/admin\n  username: admin\n  groups: [system:masters]\n",
        ]])
        #expect(maps?.map { "\($0["kind"].string ?? "") \($0["username"].string ?? "") \($0["groups"].items.compactMap { $0.string }.joined(separator: ","))" }
                == ["role system:node:{{EC2PrivateDNSName}} system:bootstrappers,system:nodes", "user admin system:masters"])
        #expect(P.awsAuthMappings(nil) == nil)
    }

    @Test func summarize() {
        let s = P.summarize(provider: P.combine(P.fromName("cluster-aks")),
                            nodes: [Self.node("n", ["cloud.google.com/gke-nodepool": "pool-1", "autopilot.gke.io/x": "y"])], version: "v1.35.8-gke.1")
        #expect(s["provider"]["provider"] == "gke" && s["provider"]["how"] == "cluster" && s["autopilot"] == true && s["nodes"] == 1 && s["awsAuth"].isNull)
    }

    @Test func heartbeatStates() {
        func beat(_ stderr: String, _ ok: Bool = false, _ stdout: String = "") -> String { KubeResources.heartbeatState(ok: ok, stdout: stdout, stderr: stderr).state }
        #expect(beat("", true, "ok") == "ok")
        #expect(beat("Error from server (Forbidden): forbidden: User \"x\" cannot get path \"/readyz\"") == "ok")
        #expect(beat("error: You must be logged in to the server (Unauthorized)") == "login")
        #expect(beat("Install gke-gcloud-auth-plugin for use with kubectl by following https://cloud.google.com/x") == "login")
        #expect(beat("ERROR: access denied: per-session MFA required") == "mfa")
        #expect(beat("Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout") == "timeout")
        #expect(beat("ERROR: kubernetes cluster \"dev\" is not found") == "agent")
        #expect(beat("Error from server (InternalError): readyz check failed") == "notready")
        #expect(beat("NotFound: Your user's Teleport role does not allow Kubernetes access. Please ask cluster administrator to ensure your role has appropriate kubernetes_groups and kubernetes_users set.") == "noaccess")
    }
}
