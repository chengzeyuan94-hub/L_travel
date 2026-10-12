"""Start the existing MCP add-on in a dedicated fresh Blender instance."""
import importlib.util
import sys
import bpy

path = '/Users/chengzeyuan/Library/Application Support/Blender/5.2/scripts/addons/addon.py'
spec = importlib.util.spec_from_file_location('baghdad_foreground_mcp', path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
if not hasattr(bpy.types.Scene, 'blendermcp_port'):
    module.register()
if not getattr(bpy.types, 'blendermcp_server', None):
    bpy.types.blendermcp_server = module.BlenderMCPServer()
bpy.types.blendermcp_server.start()
print('BAGHDAD_FOREGROUND_MCP_READY', flush=True)
