# Automated VHI Deployment

This script allows to deploy nested VHI cluster for test/dev automatically. Cluster can be deployed on top of any VHI cluster with nested virtualization enabled.

## Step 1. Prepare the physical VHI cluster
1. Cluster must have a nested virtualization enabled:
    1. Enable nested virtualization for the physical host:
        1. connect to your physical VHI node via SSH.
        2. open a file: 
        `# vi /etc/modprobe.d/dist.conf`
        4. add a new line: `options kvm-intel nested=y`
        5. reboot the host
    2. VMs should be created only after that. To check if nested is enabled:
        For the host: `# cat /sys/module/kvm_intel/parameters/nested`
        For VM, run inside VM: `# cat /proc/cpuinfo | grep vmx`
2. Cluster must have a public and private networks configured. Private network should not have a default gateway.
3. Cluster must have a flavor “xxlarge” with at least 8 vCPU and 24GB RAM. Nested VHI uses the flavor “xxlarge” by default.
4. Upload the latest VHI qcow2 template to your cluster via Admin UI or CLI (faster):
    1. Login to your physical VHI cluster master node via SSH.
    2. Download the latest VHI qcow2 template:
    `# wget https://virtuozzo.s3.amazonaws.com/vzlinux-iso-hci-5.1.0-206.qcow2`
    3. Create an image:
    `# vinfra service compute image create vz-5.1.0-206 --disk-format qcow2 --container-format bare --file vzlinux-iso-hci-5.1.0-206.qcow2 --public --wait`

## Step 2. Deploy VHI cluster
1. Read about OpenStack Heat https://docs.openstack.org/heat/latest/
2. Install OpenStack CLI on your computer https://docs.openstack.org/newton/user-guide/common/cli-install-openstack-command-line-clients.html For example, for MacOS:       # brew install openstackclient
3. Download scripts to your computer:
    `# wget https://virtuozzo.s3.amazonaws.com/vhideploy.tar.gz`
1. Extract scripts:
    `# tar -xzvf vhideploy.tar.gz`
1. Create OpenStack source file based on the provided example.
    `# vi project.sh`

```
OS_PROJECT_DOMAIN_NAME - the name of the domain to deploy the stack;
OS_USER_DOMAIN_NAME - the name of the user domain;
OS_PROJECT_NAME - the name of the project to deploy the stack;
OS_USERNAME - user name;
OS_PASSWORD - user password;
OS_AUTH_URL - the url of OpenStack endpoint, endpoint must be published and available.
```

5. Load source file:
    `# source vporokhov.sh`
6. Check that connection to OpenStack API works:
    ```
    # openstack --insecure server list
    // use --insecure option if your cluster uses a self-signed certificate
    ```
7. Deploy heat stack:
    `# openstack --insecure stack create stack_name -t vip.yaml --parameter image="vz-5.1.0-206" --parameter stack_type="hacompute" --parameter private_network="private" --parameter slave_count="2" --parameter compute_addons="k8saas,lbaas" --parameter cluster_password="Virtuozzo1"`

The minimal required configuration:

    `# openstack --insecure stack create stack_name -t vip.yaml --parameter image="vz-5.1.0-206" --parameter stack_type="compute" --parameter private_network="private" --parameter slave_count="2" --parameter cluster_password="Virtuozzo1"`

Here:
- stack_name - just an OpenStack Heat stack name;
- image - the name of the source image, image must be qcow2 and can be downloaded from https://builds.builder.corp.acronis.com/ ;
- private_network - the name of the private (virtual) network, virtual network must be connected with public network via virtual router with SNAT;
- public_network - the name of the public (physical) network, this network must have DHCP enabled and DNS configured, default name - “public”;
- slave_count - number of cluster nodes in addition to management nodes; for HA configuration, the minimal slave count must be 2;
- stack_type - VHI deployment mode: compute - cluster with storage and compute roles; hacompute - cluster with storage and compute roles, management nodes with HA.
- flavor - flavor to use for VHI nodes.
- compute_addons - what addons should be automatically installed after cluster deployment.

8. Check stack status:
    `# openstack --insecure stack lis`

9. Wait at least for 10 minutes for cluster to be deployed. After that go to the master node public IP in your browser https://<master_ip>:8888 with provided password. Check the compute cluster and other services status.
10. Reconfigure the Public network:
    1. Go to Admin UI→Compute→Network
    2. Delete the network “public”.
    3. Create a new network:
        1. Type: physical
        2. Name: public
        3. Infrastructure network: Public
        4. Untagged
        5. Subnet:
            1. IPv4
            2. CIDR, GW and DNS must be configured.
        6. Access: All projects, Full
11. Enjoy.

## Next steps
1. Connect to OpenStack CLI:  https://docs.virtuozzo.com/virtuozzo_hybrid_infrastructure_5_1_admins_guide/index.html#connecting-to-openstack-command-line-interface.html?Highlight=openstack
2. Configure OpenStack endpoint if needed: https://docs.virtuozzo.com/virtuozzo_hybrid_infrastructure_5_1_admins_guide/index.html#setting-dns-name-for-the-compute-api.html
