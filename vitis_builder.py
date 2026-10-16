import argparse
import vitis

parser = argparse.ArgumentParser()
parser.add_argument('--platform', required=True)
parser.add_argument('--hw-design', required=True, help='XSA path')
parser.add_argument('--os', default='standalone')
parser.add_argument('--cpus', nargs='+', required=True, help='CPU names, one domain and one app per CPU')
parser.add_argument('--app-prefix', required=True, help='Apps are named <prefix>-cpu<N>')
parser.add_argument('--workspace', default='workspace')
parser.add_argument('--template', default='hello_world')
args = parser.parse_args()

client = vitis.create_client()
client.set_workspace(path=args.workspace)

# Create platform and domains
platform = client.create_platform_component(name=args.platform, hw_design=args.hw_design, no_boot_bsp=True)
domains = []
for cpu in args.cpus:
    domain_name = f'{args.os}_{cpu}'
    platform.add_domain(cpu=cpu, os=args.os, name=domain_name)
    domains.append(domain_name)
platform.build()

# Create a base application for each domain, using the same template
xpfm = f"{args.workspace}/{args.platform}/export/{args.platform}/{args.platform}.xpfm"
for i, domain_name in enumerate(domains):
    app = client.create_app_component(name=f'{args.app_prefix}-cpu{i}', platform=xpfm, domain=domain_name, template=args.template)
    app.build()

# System project so all apps can run simultaneously
sys_proj = client.create_sys_project(name=args.app_prefix, platform=xpfm)
for i in range(len(domains)):
    sys_proj.add_component(name=f'{args.app_prefix}-cpu{i}')
