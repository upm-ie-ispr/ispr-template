import sys
import vitis

PLATFORM_NAME = sys.argv[1]
HW_DESIGN = sys.argv[2]
OS_NAME = sys.argv[3]
CPU_NAME = sys.argv[4]
APP_NAME = sys.argv[5]

DOMAIN_NAME = f'{OS_NAME}_{CPU_NAME}'

# Create a Vitis client object -
client = vitis.create_client()

# Set Vitis Workspace
client.set_workspace(path="workspace")

# Create System and Domain Projects
platform = client.create_platform_component(name=PLATFORM_NAME, hw_design=HW_DESIGN, no_boot_bsp=True)
domain = platform.add_domain(cpu=CPU_NAME, os=OS_NAME, name=DOMAIN_NAME)
platform.build()

# Create Application Project
app = client.create_app_component(name=APP_NAME, platform=f"workspace/{PLATFORM_NAME}/export/{PLATFORM_NAME}/{PLATFORM_NAME}.xpfm", domain=DOMAIN_NAME, template="hello_world")
app.build()
