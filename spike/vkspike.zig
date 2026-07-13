// Phase-0 de-risk spike for the Dawn→Vulkan(MoltenVK) migration.
//
// Proves the whole premise: feed dye.k-emitted SPIR-V straight to
// vkCreateShaderModule on MoltenVK and run it — at BOTH SPIR-V 1.3 (today's
// output, the migration baseline) and SPIR-V 1.4 (version-bumped + OpEntryPoint
// interface expanded, i.e. the reverted Phase-6 change).
//
// The kernel is dye.k's own `shader.compute[{[x] x*2}]`:
//   LocalSize 64,1,1 ; set0 binding0 = in (Block{rtarray<float>}),
//   binding1 = out ; out[gid.x] = in[gid.x]*2.
//
// Throwaway. Build+run:  see spike/run.sh
const std = @import("std");
const c = @cImport({
  @cDefine("VK_NO_PROTOTYPES", ""); // we still link MoltenVK's exported symbols
  @cInclude("vulkan/vulkan.h");
});

// MoltenVK exports these; declare the few we call (VK_NO_PROTOTYPES hid them).
extern fn vkCreateInstance(*const c.VkInstanceCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkInstance) c.VkResult;
extern fn vkEnumeratePhysicalDevices(c.VkInstance, *u32, ?[*]c.VkPhysicalDevice) c.VkResult;
extern fn vkGetPhysicalDeviceProperties(c.VkPhysicalDevice, *c.VkPhysicalDeviceProperties) void;
extern fn vkGetPhysicalDeviceQueueFamilyProperties(c.VkPhysicalDevice, *u32, ?[*]c.VkQueueFamilyProperties) void;
extern fn vkGetPhysicalDeviceMemoryProperties(c.VkPhysicalDevice, *c.VkPhysicalDeviceMemoryProperties) void;
extern fn vkCreateDevice(c.VkPhysicalDevice, *const c.VkDeviceCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDevice) c.VkResult;
extern fn vkGetDeviceQueue(c.VkDevice, u32, u32, *c.VkQueue) void;
extern fn vkCreateBuffer(c.VkDevice, *const c.VkBufferCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkBuffer) c.VkResult;
extern fn vkGetBufferMemoryRequirements(c.VkDevice, c.VkBuffer, *c.VkMemoryRequirements) void;
extern fn vkAllocateMemory(c.VkDevice, *const c.VkMemoryAllocateInfo, ?*const c.VkAllocationCallbacks, *c.VkDeviceMemory) c.VkResult;
extern fn vkBindBufferMemory(c.VkDevice, c.VkBuffer, c.VkDeviceMemory, c.VkDeviceSize) c.VkResult;
extern fn vkMapMemory(c.VkDevice, c.VkDeviceMemory, c.VkDeviceSize, c.VkDeviceSize, u32, *?*anyopaque) c.VkResult;
extern fn vkCreateShaderModule(c.VkDevice, *const c.VkShaderModuleCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkShaderModule) c.VkResult;
extern fn vkCreateDescriptorSetLayout(c.VkDevice, *const c.VkDescriptorSetLayoutCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDescriptorSetLayout) c.VkResult;
extern fn vkCreatePipelineLayout(c.VkDevice, *const c.VkPipelineLayoutCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkPipelineLayout) c.VkResult;
extern fn vkCreateComputePipelines(c.VkDevice, c.VkPipelineCache, u32, [*]const c.VkComputePipelineCreateInfo, ?*const c.VkAllocationCallbacks, [*]c.VkPipeline) c.VkResult;
extern fn vkCreateDescriptorPool(c.VkDevice, *const c.VkDescriptorPoolCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDescriptorPool) c.VkResult;
extern fn vkAllocateDescriptorSets(c.VkDevice, *const c.VkDescriptorSetAllocateInfo, *c.VkDescriptorSet) c.VkResult;
extern fn vkUpdateDescriptorSets(c.VkDevice, u32, [*]const c.VkWriteDescriptorSet, u32, ?[*]const c.VkCopyDescriptorSet) void;
extern fn vkCreateCommandPool(c.VkDevice, *const c.VkCommandPoolCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkCommandPool) c.VkResult;
extern fn vkAllocateCommandBuffers(c.VkDevice, *const c.VkCommandBufferAllocateInfo, *c.VkCommandBuffer) c.VkResult;
extern fn vkBeginCommandBuffer(c.VkCommandBuffer, *const c.VkCommandBufferBeginInfo) c.VkResult;
extern fn vkCmdBindPipeline(c.VkCommandBuffer, c.VkPipelineBindPoint, c.VkPipeline) void;
extern fn vkCmdBindDescriptorSets(c.VkCommandBuffer, c.VkPipelineBindPoint, c.VkPipelineLayout, u32, u32, [*]const c.VkDescriptorSet, u32, ?[*]const u32) void;
extern fn vkCmdDispatch(c.VkCommandBuffer, u32, u32, u32) void;
extern fn vkEndCommandBuffer(c.VkCommandBuffer) c.VkResult;
extern fn vkQueueSubmit(c.VkQueue, u32, [*]const c.VkSubmitInfo, c.VkFence) c.VkResult;
extern fn vkQueueWaitIdle(c.VkQueue) c.VkResult;

fn check(r: c.VkResult, what: []const u8) void {
  if (r != c.VK_SUCCESS) std.debug.panic("{s} failed: VkResult={d}", .{ what, r });
}

const N: u32 = 5;

fn run(dev: c.VkDevice, queue: c.VkQueue, qfam: u32, memprops: c.VkPhysicalDeviceMemoryProperties, spirv: []const u8, label: []const u8) !void {
  // --- host-visible memory type (MoltenVK is unified) ---
  const want = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  var memtype: u32 = 0;
  {
    var i: u32 = 0;
    while (i < memprops.memoryTypeCount) : (i += 1) {
      if (memprops.memoryTypes[i].propertyFlags & want == want) { memtype = i; break; }
    }
  }

  // --- two storage buffers (in @ binding0, out @ binding1) ---
  const bytes: c.VkDeviceSize = N * 4;
  var bufs: [2]c.VkBuffer = undefined;
  var mems: [2]c.VkDeviceMemory = undefined;
  var mapped: [2][*]f32 = undefined;
  for (0..2) |i| {
    const bi = c.VkBufferCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = bytes,
      .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    check(vkCreateBuffer(dev, &bi, null, &bufs[i]), "createBuffer");
    var req: c.VkMemoryRequirements = undefined;
    vkGetBufferMemoryRequirements(dev, bufs[i], &req);
    const ai = c.VkMemoryAllocateInfo{
      .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = req.size,
      .memoryTypeIndex = memtype,
    };
    check(vkAllocateMemory(dev, &ai, null, &mems[i]), "allocateMemory");
    check(vkBindBufferMemory(dev, bufs[i], mems[i], 0), "bindBufferMemory");
    var p: ?*anyopaque = null;
    check(vkMapMemory(dev, mems[i], 0, bytes, 0, &p), "mapMemory");
    mapped[i] = @ptrCast(@alignCast(p.?));
  }
  // input = 1..N, output = 0
  for (0..N) |k| { mapped[0][k] = @floatFromInt(k + 1); mapped[1][k] = 0; }

  // --- shader module straight from dye.k SPIR-V ---
  // @embedFile bytes aren't u32-aligned; copy into an aligned word buffer.
  var code: [4096]u32 = undefined;
  const nwords = spirv.len / 4;
  @memcpy(std.mem.sliceAsBytes(code[0..nwords]), spirv);
  var shad: c.VkShaderModule = undefined;
  const smi = c.VkShaderModuleCreateInfo{
    .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    .codeSize = spirv.len,
    .pCode = &code,
  };
  check(vkCreateShaderModule(dev, &smi, null, &shad), "createShaderModule");

  // --- descriptor set layout: 2 storage buffers ---
  const binds = [2]c.VkDescriptorSetLayoutBinding{
    .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT },
    .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT },
  };
  var dsl: c.VkDescriptorSetLayout = undefined;
  const dsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = &binds };
  check(vkCreateDescriptorSetLayout(dev, &dsli, null, &dsl), "createDSL");

  var plo: c.VkPipelineLayout = undefined;
  const pli = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
  check(vkCreatePipelineLayout(dev, &pli, null, &plo), "createPipelineLayout");

  var pipe: c.VkPipeline = undefined;
  const cpi = c.VkComputePipelineCreateInfo{
    .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    .stage = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = shad, .pName = "main" },
    .layout = plo,
    .basePipelineIndex = -1,
  };
  check(vkCreateComputePipelines(dev, null, 1, @ptrCast(&cpi), null, @ptrCast(&pipe)), "createComputePipeline");

  // --- descriptor pool + set, point at the two buffers ---
  const psz = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 };
  var pool: c.VkDescriptorPool = undefined;
  const dpi = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &psz };
  check(vkCreateDescriptorPool(dev, &dpi, null, &pool), "createDescriptorPool");
  var dset: c.VkDescriptorSet = undefined;
  const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
  check(vkAllocateDescriptorSets(dev, &dsai, &dset), "allocDescriptorSets");
  var binfo: [2]c.VkDescriptorBufferInfo = undefined;
  var writes: [2]c.VkWriteDescriptorSet = undefined;
  for (0..2) |i| {
    binfo[i] = .{ .buffer = bufs[i], .offset = 0, .range = bytes };
    writes[i] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = dset, .dstBinding = @intCast(i), .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &binfo[i] };
  }
  vkUpdateDescriptorSets(dev, 2, &writes, 0, null);

  // --- command buffer: dispatch ceil(N/64) = 1 group ---
  var cpool: c.VkCommandPool = undefined;
  const cpci = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qfam };
  check(vkCreateCommandPool(dev, &cpci, null, &cpool), "createCommandPool");
  var cb: c.VkCommandBuffer = undefined;
  const cbai = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
  check(vkAllocateCommandBuffers(dev, &cbai, &cb), "allocCommandBuffer");
  const bbi = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
  check(vkBeginCommandBuffer(cb, &bbi), "begin");
  vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
  vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_COMPUTE, plo, 0, 1, @ptrCast(&dset), 0, null);
  vkCmdDispatch(cb, (N + 63) / 64, 1, 1);
  check(vkEndCommandBuffer(cb), "end");
  const si = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cb) };
  check(vkQueueSubmit(queue, 1, @ptrCast(&si), null), "submit");
  check(vkQueueWaitIdle(queue), "waitIdle");

  // --- verify out[k] == 2*(k+1) ---
  var ok = true;
  for (0..N) |k| {
    const want_v: f32 = @floatFromInt(2 * (k + 1));
    if (mapped[1][k] != want_v) ok = false;
  }
  std.debug.print("  [{s}] out = ", .{label});
  for (0..N) |k| std.debug.print("{d} ", .{mapped[1][k]});
  std.debug.print("  => {s}\n", .{if (ok) "PASS" else "FAIL"});
  if (!ok) return error.WrongResult;
}

pub fn main() !void {
  // --- instance ---
  // We link libMoltenVK directly (no Vulkan loader), so VK_KHR_portability_enumeration
  // (a *loader* extension) neither exists nor is needed: MoltenVK hands us its device
  // directly. No instance extensions, no portability-enumerate flag.
  const app = c.VkApplicationInfo{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vkspike", .apiVersion = c.VK_API_VERSION_1_2 };
  const ici = c.VkInstanceCreateInfo{
    .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &app,
  };
  var inst: c.VkInstance = undefined;
  check(vkCreateInstance(&ici, null, &inst), "createInstance");

  var ndev: u32 = 0;
  check(vkEnumeratePhysicalDevices(inst, &ndev, null), "enumPhysDev(count)");
  if (ndev == 0) return error.NoDevice;
  var devs: [8]c.VkPhysicalDevice = undefined;
  ndev = @min(ndev, 8);
  check(vkEnumeratePhysicalDevices(inst, &ndev, &devs), "enumPhysDev");
  const pdev = devs[0];
  var props: c.VkPhysicalDeviceProperties = undefined;
  vkGetPhysicalDeviceProperties(pdev, &props);
  std.debug.print("device: {s}  Vulkan {d}.{d}.{d}\n", .{
    @as([*:0]const u8, @ptrCast(&props.deviceName)),
    c.VK_API_VERSION_MAJOR(props.apiVersion), c.VK_API_VERSION_MINOR(props.apiVersion), c.VK_API_VERSION_PATCH(props.apiVersion),
  });

  // compute queue family
  var nqf: u32 = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nqf, null);
  var qfs: [16]c.VkQueueFamilyProperties = undefined;
  nqf = @min(nqf, 16);
  vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nqf, &qfs);
  var qfam: u32 = 0;
  { var i: u32 = 0; while (i < nqf) : (i += 1) { if (qfs[i].queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) { qfam = i; break; } } }

  var memprops: c.VkPhysicalDeviceMemoryProperties = undefined;
  vkGetPhysicalDeviceMemoryProperties(pdev, &memprops);

  // device with portability_subset
  const dev_exts = [_][*c]const u8{"VK_KHR_portability_subset"};
  const prio: f32 = 1.0;
  const qci = c.VkDeviceQueueCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qfam, .queueCount = 1, .pQueuePriorities = &prio };
  const dci = c.VkDeviceCreateInfo{
    .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .queueCreateInfoCount = 1,
    .pQueueCreateInfos = &qci,
    .enabledExtensionCount = dev_exts.len,
    .ppEnabledExtensionNames = &dev_exts,
  };
  var dev: c.VkDevice = undefined;
  check(vkCreateDevice(pdev, &dci, null, &dev), "createDevice");
  var queue: c.VkQueue = undefined;
  vkGetDeviceQueue(dev, qfam, 0, &queue);

  const spv13 = @embedFile("k13.spv");
  const spv14 = @embedFile("k14.spv");
  std.debug.print("SPIR-V ingest test (dye.k `shader.compute[x*2]`, input 1..{d}):\n", .{N});
  try run(dev, queue, qfam, memprops, spv13, "SPIR-V 1.3 baseline");
  try run(dev, queue, qfam, memprops, spv14, "SPIR-V 1.4 (iface-expanded)");
  std.debug.print("\nMoltenVK ingests dye.k SPIR-V 1.4 and computes correctly. Premise proven.\n", .{});
}
