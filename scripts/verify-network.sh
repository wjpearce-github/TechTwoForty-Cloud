#!/usr/bin/env bash
# Checks your hand-built network against the Cloud project's checkpoints 1 to 5.
# Read-only: it only runs "describe" calls and changes nothing in your account.
#
#   bash scripts/verify-network.sh
#
# Needs the AWS CLI signed in to the account and Region you built in.

set -uo pipefail

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; echo "        -> $2"; fail=$((fail + 1)); }
q()   { aws ec2 "$@" --output text 2>/dev/null; }

echo "Cloud project: checking the network you built"
echo

# ---- Checkpoint 1: the VPC and two subnets ----
VPC=$(q describe-vpcs --filters Name=tag:Name,Values=course-vpc --query 'Vpcs[0].VpcId')
if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then
  bad "No VPC called course-vpc" "Phase 1: VPC, Create VPC, VPC only, 10.0.0.0/16"
  echo; echo "$pass passed, $fail failed"; exit 1
fi
CIDR=$(q describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock')
[ "$CIDR" = "10.0.0.0/16" ] && ok "course-vpc is 10.0.0.0/16 ($VPC)" || bad "course-vpc is $CIDR" "It should be 10.0.0.0/16"

subnet() { q describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$1" --query 'Subnets[0].SubnetId'; }
PUB=$(subnet course-public)
PRIV=$(subnet course-private)
PUB_CIDR=$(q describe-subnets --subnet-ids "$PUB" --query 'Subnets[0].CidrBlock')
PRIV_CIDR=$(q describe-subnets --subnet-ids "$PRIV" --query 'Subnets[0].CidrBlock')
[ "$PUB_CIDR" = "10.0.1.0/24" ] && ok "course-public is 10.0.1.0/24" || bad "course-public missing or wrong CIDR ($PUB_CIDR)" "Phase 1: 10.0.1.0/24"
[ "$PRIV_CIDR" = "10.0.2.0/24" ] && ok "course-private is 10.0.2.0/24" || bad "course-private missing or wrong CIDR ($PRIV_CIDR)" "Phase 1: 10.0.2.0/24"

# ---- Checkpoint 2: two gateways ----
IGW=$(q describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[0].InternetGatewayId')
[ -n "$IGW" ] && [ "$IGW" != "None" ] && ok "An internet gateway is attached ($IGW)" || bad "No internet gateway attached to course-vpc" "Phase 2: create course-igw, then Actions, Attach to VPC"
NAT=$(q describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" Name=state,Values=available --query 'NatGateways[0].NatGatewayId')
NAT_SUBNET=$(q describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" Name=state,Values=available --query 'NatGateways[0].SubnetId')
if [ -n "$NAT" ] && [ "$NAT" != "None" ]; then
  [ "$NAT_SUBNET" = "$PUB" ] && ok "NAT gateway is available, in course-public ($NAT)" || bad "NAT gateway is in the wrong subnet" "It belongs in course-public: it needs a public address"
else
  bad "No available NAT gateway in course-vpc" "Phase 2: create course-nat in course-public with a new Elastic IP"
fi

# ---- Checkpoint 3: route tables ----
route_target() {  # $1 subnet, $2 field
  q describe-route-tables --filters "Name=association.subnet-id,Values=$1" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].$2 | [0]"
}
[ "$IGW" != "None" ] && [ -n "$IGW" ] && [ "$(route_target "$PUB" GatewayId)" = "$IGW" ] && ok "course-public routes 0.0.0.0/0 to the internet gateway" || bad "course-public has no 0.0.0.0/0 route to the IGW" "Phase 3: course-public-rt, add route, associate course-public"
[ "$NAT" != "None" ] && [ -n "$NAT" ] && [ "$(route_target "$PRIV" NatGatewayId)" = "$NAT" ] && ok "course-private routes 0.0.0.0/0 to the NAT gateway" || bad "course-private has no 0.0.0.0/0 route to the NAT" "Phase 3: course-private-rt, add route, associate course-private"

# ---- Checkpoint 4: security groups ----
sg() { q describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId'; }
PUB_SG=$(sg course-public-sg)
PRIV_SG=$(sg course-private-sg)
PUB_SRC=$(q describe-security-groups --group-ids "$PUB_SG" --query 'SecurityGroups[0].IpPermissions[?ToPort==`22`].IpRanges[].CidrIp')
case "$PUB_SRC" in
  */32) ok "course-public-sg allows SSH from one address only ($PUB_SRC)" ;;
  *)    bad "course-public-sg SSH source is '$PUB_SRC'" "Phase 4: SSH, port 22, source My IP (ends in /32)" ;;
esac
PRIV_SRC=$(q describe-security-groups --group-ids "$PRIV_SG" --query 'SecurityGroups[0].IpPermissions[?ToPort==`22`].UserIdGroupPairs[].GroupId')
PRIV_CIDRS=$(q describe-security-groups --group-ids "$PRIV_SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp')
if [ "$PRIV_SRC" = "$PUB_SG" ] && [ -z "$PRIV_CIDRS" ]; then
  ok "course-private-sg allows SSH from course-public-sg only, by reference"
else
  bad "course-private-sg is not 'SSH from course-public-sg only'" "Phase 4: the source must be the security group itself, not an IP"
fi

# ---- Checkpoint 5: the two servers ----
inst() {  # $1 Name tag, $2 field
  q describe-instances --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2"
}
B_SUBNET=$(inst course-bastion SubnetId); B_IP=$(inst course-bastion PublicIpAddress)
A_SUBNET=$(inst course-app SubnetId);     A_IP=$(inst course-app PublicIpAddress)
[ "$B_SUBNET" != "None" ] && [ "$B_SUBNET" = "$PUB" ] && [ -n "$B_IP" ] && [ "$B_IP" != "None" ] && ok "course-bastion runs in course-public with public IP $B_IP" || bad "course-bastion is not running in course-public with a public IP" "Phase 5: auto-assign public IP Enable"
[ "$A_SUBNET" != "None" ] && [ "$A_SUBNET" = "$PRIV" ] && [ "$A_IP" = "None" ] && ok "course-app runs in course-private with no public IP" || bad "course-app is missing, in the wrong subnet, or has a public IP" "Phase 5: course-private, auto-assign public IP Disable"

echo
echo "$pass passed, $fail failed"
echo "Last proof is yours: ssh to the bastion, hop to course-app, curl -I https://aws.amazon.com (HTTP/2 200)."
echo "Then tear it down and run: bash scripts/teardown-check.sh"
exit "$fail"
