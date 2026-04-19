## Kubeadm Cluster Setup Scripts

Here is the supporting documentation and video demo.

1. [Documentation - Kubeadm Cluster Setup Guide](https://devopscube.com/setup-kubernetes-cluster-kubeadm/)
2. [Kubeadm workflow explanation and demo video](https://youtu.be/xX52dc3u2HU)

## Kubernetes Certification Voucher (UpTo 45% OFF) 🎉

If you are learning Kubernetes and preparing for Kubernetes certifications, these voucher codes will help you save money on your certification registration.

CKA, CKAD, CKS, KCNA etc.. aspirants can **save 35%** today

> [!IMPORTANT]
> Use code **35KUBECT** at https://kube.promo/devops. It is a limited-time offer from the Linux Foundation.

The following are the best bundles to **save upto 45%** with code **35KUBESC**

- CKA + CKAD: [kube.promo/cka-ckad](https://kube.promo/cka-ckad)
- CKA + CKS Bundle: [kube.promo/bundle](https://kube.promo/bundle)
- CKA + CKAD + CKS Exam bundle: [kube.promo/k8s-bundle](https://kube.promo/k8s-bundle)

> Checkout all the latest bundle offers at [Linux Foundation Coupon](https://github.com/techiescamp/linux-foundation-coupon) repo.

> [!NOTE]
>⌛ Act fast—this limited-time offer won’t be around much longer!
> You have one year of validity to appear for the certification exam after registration

## Organized Kubernetes & CKA Learning

If you Looking for an organized way to learn Kubernetes and prepare for the CKA exam with practice questions? 

> Check out our [Complete CKA Certification Course](https://courses.devopscube.com/p/cka-complete-prep-course-practice-tests). 

It includes illustrations, hands-on exercises, real-world examples, and dedicated Discord support. 

> [!NOTE]
>⌛ For a lmited time, use code **DCUBE30** to get 30% OFF today!

## Kubernetes Learning Roadmap

If you are learning Kubernetes, check out the [kubernetes Learning Roadmap](https://github.com/techiescamp/kubernetes-learning-path)


sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube

kubeadm join 10.0.2.185:6443 --token 3c5qb8.7l46v7i8jsoo2dz9 \
        --discovery-token-ca-cert-hash sha256:0f6ccebc9facaa97cc6ba6951c468f4683b318c8970c6a99b01a71cc7dce1356

kubectl get po -n kube-system
kubectl get --raw='readyz?verbose?'
kubeadm token create --print-join-command
kubectl get nodes
kubectl label node ip-10-0-3-152.eu-west-1.compute.internal node-role.kubernetes.io/worker=worker
kubectl label node ip-10-0-3-152.eu-west-1.compute.internal node-role.kubernetes.io/worker=worker-node
kubectl apply -f metrics-server.yaml

