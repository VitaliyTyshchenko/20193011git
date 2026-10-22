# step 1 azure 

#!/bin/bash
# step 1 usage: ./azure.sh 1
# step 3 after aws is ready  usage:  ./azure.sh 2 <t1_ip> <t2_ip> <t1_psk> <t2_psk>

RG=rg-hub
L=uksouth
VNET=vnet-uksouth-1
GW=vpngw
TAGS="Project=autobgpwiths3"

if [ "$1" = "1" ]; then

  az group create -n $RG -l $L --tags $TAGS

  az network vnet create -g $RG -n $VNET -l $L \
    --address-prefixes 10.20.0.0/16 \
    --subnet-name GatewaySubnet --subnet-prefixes 10.20.255.0/27 \
    --tags $TAGS

  az network vnet subnet create -g $RG --vnet-name $VNET -n workload \
    --address-prefixes 10.20.1.0/24

  az network public-ip create -g $RG -n gw-pip -l $L --sku Standard \
    --allocation-method Static --tags $TAGS

  az network vnet-gateway create -g $RG -n $GW -l $L --vnet $VNET \
    --public-ip-addresses gw-pip --gateway-type Vpn --vpn-type RouteBased \
    --sku VpnGw2AZ --asn 65515 --tags $TAGS

  az network vnet-gateway update -g $RG -n $GW \
    --set bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses="['169.254.21.2','169.254.22.2']"

  az vm create -g $RG -n azure-test-vm -l $L --image Ubuntu2204 --size Standard_B1s \
    --vnet-name $VNET --subnet workload --public-ip-address "" \
    --admin-username azureuser --generate-ssh-keys --tags $TAGS

  echo "Azure VM IP:"
  az vm show -d -g $RG -n azure-test-vm --query privateIps -o tsv
  echo "Azure_GW_IP (put into aws.tf AZURE_GW_IP):"
  az network public-ip show -g $RG -n gw-pip --query ipAddress -o tsv

else

  T1_IP=$2
  T2_IP=$3
  T1_PSK=$4
  T2_PSK=$5

  az network local-gateway create -g $RG -n aws-lng1 -l $L --gateway-ip-address $T1_IP \
    --asn 64512 --bgp-peering-address 169.254.21.1 \
    --local-address-prefixes 169.254.21.1/32 --tags $TAGS
  az network local-gateway create -g $RG -n aws-lng2 -l $L --gateway-ip-address $T2_IP \
    --asn 64512 --bgp-peering-address 169.254.22.1 \
    --local-address-prefixes 169.254.22.1/32 --tags $TAGS

  az network vpn-connection create -g $RG -n to-aws1 -l $L --vnet-gateway1 $GW \
    --local-gateway2 aws-lng1 --shared-key "$T1_PSK" --enable-bgp --tags $TAGS
  az network vpn-connection create -g $RG -n to-aws2 -l $L --vnet-gateway1 $GW \
    --local-gateway2 aws-lng2 --shared-key "$T2_PSK" --enable-bgp --tags $TAGS

  az network vnet-gateway list-bgp-peer-status -g $RG -n $GW -o table

fi

# aws ec2 search-transit-gateway-routes --region us-east-1 --transit-gateway-route-table-id <tgw-rtb-id> --filters "Name=type,Values=propagated" --output table
# az network vnet-gateway list-learned-routes -g rg-hub -n vpngw -o table

# Network          NextHop       Origin    SourcePeer    AsPath    Weight
# ---------------  ------------  --------  ------------  --------  --------
# 10.20.0.0/16                   Network   10.20.255.30            32768
# 169.254.21.1/32                Network   10.20.255.30            32768
# 10.10.0.0/16     169.254.21.1  EBgp      169.254.21.1  64512     32768
# 10.10.0.0/16     169.254.22.1  EBgp      169.254.22.1  64512     32768
# 169.254.22.1/32                Network   10.20.255.30            32768


