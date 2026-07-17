// Vulkan (MoltenVK) compute context for the ink GPU extension.
//
// Phase 2 of the Dawn→Vulkan migration (doc/design/vulkan-migration.md): the
// SPIR-V-native compute backend. Feeds dye.k's SPIR-V straight to
// vkCreateShaderModule — no Tint reader, no WGSL, full SPIR-V version range.
//
// Deliberately simple, leaning on MoltenVK's unified memory:
//   * every buffer is HOST_VISIBLE|HOST_COHERENT and persistently mapped, so
//     upload/readback are plain memcpy — no staging buffers, no copy commands.
//   * every op is synchronous (submit + vkQueueWaitIdle), so the descriptor pool
//     can be reset per op and there is no fence/semaphore bookkeeping.
// Correctness-first; the render backend (Phase 3) will add real frame sync.
//
// No Vulkan loader: we link libMoltenVK directly, which exports the core vk*
// symbols. So NO VK_KHR_portability_enumeration (loader-only); only the device
// extension VK_KHR_portability_subset. (Proven by spike/vkspike.zig.)
const std = @import("std");
const c = @cImport({
  @cDefine("VK_NO_PROTOTYPES", "");
  @cInclude("vulkan/vulkan.h");
});

// MoltenVK exports these directly; VK_NO_PROTOTYPES hid the header decls.
extern fn vkCreateInstance(*const c.VkInstanceCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkInstance) c.VkResult;
extern fn vkDestroyInstance(c.VkInstance, ?*const c.VkAllocationCallbacks) void;
extern fn vkEnumeratePhysicalDevices(c.VkInstance, *u32, ?[*]c.VkPhysicalDevice) c.VkResult;
extern fn vkGetPhysicalDeviceProperties(c.VkPhysicalDevice, *c.VkPhysicalDeviceProperties) void;
extern fn vkGetPhysicalDeviceQueueFamilyProperties(c.VkPhysicalDevice, *u32, ?[*]c.VkQueueFamilyProperties) void;
extern fn vkGetPhysicalDeviceMemoryProperties(c.VkPhysicalDevice, *c.VkPhysicalDeviceMemoryProperties) void;
extern fn vkGetPhysicalDeviceProperties2(c.VkPhysicalDevice, *c.VkPhysicalDeviceProperties2) void;
extern fn vkGetPhysicalDeviceFeatures2(c.VkPhysicalDevice, *c.VkPhysicalDeviceFeatures2) void;
extern fn vkEnumerateDeviceExtensionProperties(c.VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]c.VkExtensionProperties) c.VkResult;
extern fn vkCreateDevice(c.VkPhysicalDevice, *const c.VkDeviceCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDevice) c.VkResult;
extern fn vkDestroyDevice(c.VkDevice, ?*const c.VkAllocationCallbacks) void;
extern fn vkGetDeviceQueue(c.VkDevice, u32, u32, *c.VkQueue) void;
extern fn vkCreateBuffer(c.VkDevice, *const c.VkBufferCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkBuffer) c.VkResult;
extern fn vkDestroyBuffer(c.VkDevice, c.VkBuffer, ?*const c.VkAllocationCallbacks) void;
extern fn vkGetBufferMemoryRequirements(c.VkDevice, c.VkBuffer, *c.VkMemoryRequirements) void;
extern fn vkAllocateMemory(c.VkDevice, *const c.VkMemoryAllocateInfo, ?*const c.VkAllocationCallbacks, *c.VkDeviceMemory) c.VkResult;
extern fn vkFreeMemory(c.VkDevice, c.VkDeviceMemory, ?*const c.VkAllocationCallbacks) void;
extern fn vkBindBufferMemory(c.VkDevice, c.VkBuffer, c.VkDeviceMemory, c.VkDeviceSize) c.VkResult;
extern fn vkMapMemory(c.VkDevice, c.VkDeviceMemory, c.VkDeviceSize, c.VkDeviceSize, u32, *?*anyopaque) c.VkResult;
extern fn vkCreateShaderModule(c.VkDevice, *const c.VkShaderModuleCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkShaderModule) c.VkResult;
extern fn vkDestroyShaderModule(c.VkDevice, c.VkShaderModule, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateDescriptorSetLayout(c.VkDevice, *const c.VkDescriptorSetLayoutCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDescriptorSetLayout) c.VkResult;
extern fn vkDestroyDescriptorSetLayout(c.VkDevice, c.VkDescriptorSetLayout, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreatePipelineLayout(c.VkDevice, *const c.VkPipelineLayoutCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkPipelineLayout) c.VkResult;
extern fn vkDestroyPipelineLayout(c.VkDevice, c.VkPipelineLayout, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateComputePipelines(c.VkDevice, c.VkPipelineCache, u32, [*]const c.VkComputePipelineCreateInfo, ?*const c.VkAllocationCallbacks, [*]c.VkPipeline) c.VkResult;
extern fn vkDestroyPipeline(c.VkDevice, c.VkPipeline, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateDescriptorPool(c.VkDevice, *const c.VkDescriptorPoolCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkDescriptorPool) c.VkResult;
extern fn vkDestroyDescriptorPool(c.VkDevice, c.VkDescriptorPool, ?*const c.VkAllocationCallbacks) void;
extern fn vkResetDescriptorPool(c.VkDevice, c.VkDescriptorPool, u32) c.VkResult;
extern fn vkAllocateDescriptorSets(c.VkDevice, *const c.VkDescriptorSetAllocateInfo, *c.VkDescriptorSet) c.VkResult;
extern fn vkUpdateDescriptorSets(c.VkDevice, u32, [*]const c.VkWriteDescriptorSet, u32, ?[*]const c.VkCopyDescriptorSet) void;
extern fn vkCreateCommandPool(c.VkDevice, *const c.VkCommandPoolCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkCommandPool) c.VkResult;
extern fn vkDestroyCommandPool(c.VkDevice, c.VkCommandPool, ?*const c.VkAllocationCallbacks) void;
extern fn vkAllocateCommandBuffers(c.VkDevice, *const c.VkCommandBufferAllocateInfo, *c.VkCommandBuffer) c.VkResult;
extern fn vkResetCommandPool(c.VkDevice, c.VkCommandPool, u32) c.VkResult;
extern fn vkBeginCommandBuffer(c.VkCommandBuffer, *const c.VkCommandBufferBeginInfo) c.VkResult;
extern fn vkCmdBindPipeline(c.VkCommandBuffer, c.VkPipelineBindPoint, c.VkPipeline) void;
extern fn vkCmdBindDescriptorSets(c.VkCommandBuffer, c.VkPipelineBindPoint, c.VkPipelineLayout, u32, u32, [*]const c.VkDescriptorSet, u32, ?[*]const u32) void;
extern fn vkCmdDispatch(c.VkCommandBuffer, u32, u32, u32) void;
extern fn vkCmdPipelineBarrier(c.VkCommandBuffer, c.VkPipelineStageFlags, c.VkPipelineStageFlags, c.VkDependencyFlags, u32, ?[*]const c.VkMemoryBarrier, u32, ?[*]const c.VkBufferMemoryBarrier, u32, ?[*]const c.VkImageMemoryBarrier) void;
extern fn vkEndCommandBuffer(c.VkCommandBuffer) c.VkResult;
extern fn vkQueueSubmit(c.VkQueue, u32, [*]const c.VkSubmitInfo, c.VkFence) c.VkResult;
extern fn vkQueueWaitIdle(c.VkQueue) c.VkResult;
extern fn vkDeviceWaitIdle(c.VkDevice) c.VkResult;
// ── windowed rendering (surface / swapchain / present / sync) ──────────────────
extern fn vkDestroySurfaceKHR(c.VkInstance, c.VkSurfaceKHR, ?*const c.VkAllocationCallbacks) void;
extern fn vkGetPhysicalDeviceSurfaceSupportKHR(c.VkPhysicalDevice, u32, c.VkSurfaceKHR, *c.VkBool32) c.VkResult;
extern fn vkGetPhysicalDeviceSurfaceCapabilitiesKHR(c.VkPhysicalDevice, c.VkSurfaceKHR, *c.VkSurfaceCapabilitiesKHR) c.VkResult;
extern fn vkGetPhysicalDeviceSurfaceFormatsKHR(c.VkPhysicalDevice, c.VkSurfaceKHR, *u32, ?[*]c.VkSurfaceFormatKHR) c.VkResult;
extern fn vkCreateSwapchainKHR(c.VkDevice, *const c.VkSwapchainCreateInfoKHR, ?*const c.VkAllocationCallbacks, *c.VkSwapchainKHR) c.VkResult;
extern fn vkDestroySwapchainKHR(c.VkDevice, c.VkSwapchainKHR, ?*const c.VkAllocationCallbacks) void;
extern fn vkGetSwapchainImagesKHR(c.VkDevice, c.VkSwapchainKHR, *u32, ?[*]c.VkImage) c.VkResult;
extern fn vkAcquireNextImageKHR(c.VkDevice, c.VkSwapchainKHR, u64, c.VkSemaphore, c.VkFence, *u32) c.VkResult;
extern fn vkQueuePresentKHR(c.VkQueue, *const c.VkPresentInfoKHR) c.VkResult;
extern fn vkCreateImageView(c.VkDevice, *const c.VkImageViewCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkImageView) c.VkResult;
extern fn vkDestroyImageView(c.VkDevice, c.VkImageView, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateRenderPass(c.VkDevice, *const c.VkRenderPassCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkRenderPass) c.VkResult;
extern fn vkDestroyRenderPass(c.VkDevice, c.VkRenderPass, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateFramebuffer(c.VkDevice, *const c.VkFramebufferCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkFramebuffer) c.VkResult;
extern fn vkDestroyFramebuffer(c.VkDevice, c.VkFramebuffer, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateSemaphore(c.VkDevice, *const c.VkSemaphoreCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkSemaphore) c.VkResult;
extern fn vkDestroySemaphore(c.VkDevice, c.VkSemaphore, ?*const c.VkAllocationCallbacks) void;
extern fn vkCreateFence(c.VkDevice, *const c.VkFenceCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkFence) c.VkResult;
extern fn vkDestroyFence(c.VkDevice, c.VkFence, ?*const c.VkAllocationCallbacks) void;
extern fn vkWaitForFences(c.VkDevice, u32, [*]const c.VkFence, c.VkBool32, u64) c.VkResult;
extern fn vkResetFences(c.VkDevice, u32, [*]const c.VkFence) c.VkResult;
extern fn vkCmdBeginRenderPass(c.VkCommandBuffer, *const c.VkRenderPassBeginInfo, c.VkSubpassContents) void;
extern fn vkCmdEndRenderPass(c.VkCommandBuffer) void;
extern fn vkCreateImage(c.VkDevice, *const c.VkImageCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkImage) c.VkResult;
extern fn vkDestroyImage(c.VkDevice, c.VkImage, ?*const c.VkAllocationCallbacks) void;
extern fn vkGetImageMemoryRequirements(c.VkDevice, c.VkImage, *c.VkMemoryRequirements) void;
extern fn vkBindImageMemory(c.VkDevice, c.VkImage, c.VkDeviceMemory, c.VkDeviceSize) c.VkResult;
extern fn vkCreateGraphicsPipelines(c.VkDevice, c.VkPipelineCache, u32, [*]const c.VkGraphicsPipelineCreateInfo, ?*const c.VkAllocationCallbacks, [*]c.VkPipeline) c.VkResult;
extern fn vkCmdBindVertexBuffers(c.VkCommandBuffer, u32, u32, [*]const c.VkBuffer, [*]const c.VkDeviceSize) void;
extern fn vkCmdDraw(c.VkCommandBuffer, u32, u32, u32, u32) void;
extern fn vkCmdSetViewport(c.VkCommandBuffer, u32, u32, [*]const c.VkViewport) void;
extern fn vkCmdSetScissor(c.VkCommandBuffer, u32, u32, [*]const c.VkRect2D) void;
extern fn vkCmdCopyImageToBuffer(c.VkCommandBuffer, c.VkImage, c.VkImageLayout, c.VkBuffer, u32, [*]const c.VkBufferImageCopy) void;
extern fn vkCreateSampler(c.VkDevice, *const c.VkSamplerCreateInfo, ?*const c.VkAllocationCallbacks, *c.VkSampler) c.VkResult;
extern fn vkDestroySampler(c.VkDevice, c.VkSampler, ?*const c.VkAllocationCallbacks) void;
extern fn vkCmdCopyBufferToImage(c.VkCommandBuffer, c.VkBuffer, c.VkImage, c.VkImageLayout, u32, [*]const c.VkBufferImageCopy) void;
extern fn vkGetInstanceProcAddr(c.VkInstance, [*c]const u8) c.PFN_vkVoidFunction;
// GLFW Vulkan surface (libglfw3). glfwInitVulkanLoader points GLFW at MoltenVK's
// directly-linked vkGetInstanceProcAddr (no libvulkan loader present).
extern fn glfwInitVulkanLoader(c.PFN_vkGetInstanceProcAddr) void;
extern fn glfwCreateWindowSurface(c.VkInstance, ?*anyopaque, ?*const c.VkAllocationCallbacks, *c.VkSurfaceKHR) c.VkResult;

// Call once before glfwInit(): GLFW resolves Vulkan through statically-linked MoltenVK.
pub fn initGlfwLoader() void {
  glfwInitVulkanLoader(vkGetInstanceProcAddr);
}

pub const Error = error{ VulkanInit, NoDevice, OutOfMemory, ShaderModule, Pipeline };

fn ok(r: c.VkResult) bool {
  return r == c.VK_SUCCESS;
}

pub const MAX_BIND = 8;
pub const FRAMES = 2; // frames in flight for windowed rendering

// dye.k emits SPIR-V 1.4 natively (version word 0x00010400 + full-interface
// OpEntryPoint) since the Dawn cutover; the old INK_SPV14 maybeBump transform
// that proved 1.4 on MoltenVK was folded into the compiler and removed.
pub const MESH_UNI_FLOATS = 32; // 8 vec4 per-draw uniform block
const UNI_SLOT = 256; // bytes per uniform slot (alignment-friendly)
const MAX_MCALLS = 1024; // max uniform mesh draws per frame

// Deferred submission: dispatches are RECORDED into one running command buffer
// and submitted+waited only at readback (sync). This is both fast (one host wait
// per readback, not per dispatch) and correct: Metal only tracks memory hazards
// *within* a single command buffer, so a pipeline barrier across separate
// submissions is a no-op on MoltenVK (that raced). Keeping the chain in one
// command buffer lets Metal's automatic hazard tracking order it. POOL_SETS caps
// how many descriptor sets one batch may record before we must flush and reset.
const POOL_SETS = 512;

pub const Buffer = struct {
  buf: c.VkBuffer,
  mem: c.VkDeviceMemory,
  size: u64,
  mapped: [*]u8,
  uniform: bool,
};

pub const Pipeline = struct {
  pipe: c.VkPipeline,
  layout: c.VkPipelineLayout,
  dsl: c.VkDescriptorSetLayout,
  module: c.VkShaderModule,
  nbind: u32,
  uni_idx: i32, // binding index of the uniform buffer, or -1 (all storage)
  wgx: u32,
};

pub const MeshPipe = struct {
  pipe: c.VkPipeline,
  layout: c.VkPipelineLayout,
  vmod: c.VkShaderModule,
  fmod: c.VkShaderModule,
  stride: u32, // vertex stride in bytes
  has_uniform: bool, // pipeline layout includes the @group(0) uniform block
  n_tex: u32, // textures sampled at @group(1) (0 = none)
  tex_dsl: c.VkDescriptorSetLayout, // @group(1) layout (n images + 1 sampler), or null
};

// Vertex-pulling pipeline (kk2 §5): no vertex-input state; the vertex shader reads
// `nbuf` resident storage buffers (set 0, VERTEX stage) indexed by gl_VertexIndex,
// and the draw is vkCmdDraw(count) with no vertex buffer bound.
pub const PullPipe = struct {
  pipe: c.VkPipeline,
  layout: c.VkPipelineLayout,
  dsl: c.VkDescriptorSetLayout, // set 0: nbuf storage buffers (vertex stage)
  vmod: c.VkShaderModule,
  fmod: c.VkShaderModule,
  nbuf: u32,
};

pub const Texture = struct {
  img: c.VkImage,
  mem: c.VkDeviceMemory,
  view: c.VkImageView,
  sampler: c.VkSampler,
};

// Device capabilities the kk compiler schedules around (doc/design/kk.md §4):
// subgroup ops → whole-buffer reductions/scans; descriptor indexing → bindless
// textures; buffer device address → bindless buffers; float atomics → native
// f32 scatter-add (else the fixed-point trick). Feature-gated, never assumed.
pub const Caps = struct {
  api_major: u32,
  api_minor: u32,
  subgroup_size: u32,
  sg_arith: bool,   // OpGroupNonUniform arithmetic (reduce/scan)
  sg_ballot: bool,
  sg_shuffle: bool,
  desc_index: bool,     // Vulkan12Features.descriptorIndexing
  runtime_array: bool,  // …runtimeDescriptorArray (bindless texture arrays)
  bda: bool,            // …bufferDeviceAddress (PhysicalStorageBuffer64)
  f16: bool,            // …shaderFloat16
  atomic_fadd: bool,    // VK_EXT_shader_atomic_float shaderBufferFloat32AtomicAdd
};

// Feature-enable chain for VkDeviceCreateInfo.pNext. The three structs point at
// each other, so they must live in one place that outlives vkCreateDevice AND be
// re-linked after any by-value copy (Zig copies the return, invalidating the
// helper-local self-pointers) — hence link(), called at the create site.
pub const Features = struct {
  f2: c.VkPhysicalDeviceFeatures2,
  v12: c.VkPhysicalDeviceVulkan12Features,
  af: c.VkPhysicalDeviceShaderAtomicFloatFeaturesEXT,
  has_af: bool,
  pub fn link(self: *Features) void {
    self.f2.pNext = @ptrCast(&self.v12);
    self.v12.pNext = if (self.has_af) @as(?*anyopaque, @ptrCast(&self.af)) else null;
  }
};

// Enable exactly the queried caps (never assume). f2.pNext is left null here;
// link() wires the chain at the call site. atomic-float is chained only when the
// EXT is present — querying/enabling an unknown feature struct is UB per spec.
fn enabledFeatures(caps: Caps) Features {
  const T = c.VkBool32;
  return .{
    .has_af = caps.atomic_fadd,
    .f2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 },
    .v12 = .{
      .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
      .descriptorIndexing = @as(T, if (caps.desc_index) c.VK_TRUE else c.VK_FALSE),
      .runtimeDescriptorArray = @as(T, if (caps.runtime_array) c.VK_TRUE else c.VK_FALSE),
      .bufferDeviceAddress = @as(T, if (caps.bda) c.VK_TRUE else c.VK_FALSE),
      .shaderFloat16 = @as(T, if (caps.f16) c.VK_TRUE else c.VK_FALSE),
    },
    .af = .{
      .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT,
      .shaderBufferFloat32AtomicAdd = @as(T, if (caps.atomic_fadd) c.VK_TRUE else c.VK_FALSE),
    },
  };
}

pub const Vk = struct {
  instance: c.VkInstance,
  pdev: c.VkPhysicalDevice,
  dev: c.VkDevice,
  queue: c.VkQueue,
  qfam: u32,
  memtype: u32, // HOST_VISIBLE|HOST_COHERENT memory type index
  cmd_pool: c.VkCommandPool,
  desc_pool: c.VkDescriptorPool,
  cur: c.VkCommandBuffer, // the open recording command buffer (when recording)
  recording: bool, // is there un-submitted recorded work
  nsets: u32, // descriptor sets recorded into the current batch

  // ── windowed rendering (undefined/zero when headless) ──
  windowed: bool,
  surface: c.VkSurfaceKHR,
  swapchain: c.VkSwapchainKHR,
  swap_format: c.VkFormat,
  swap_colorspace: c.VkColorSpaceKHR,
  swap_extent: c.VkExtent2D,
  n_images: u32,
  images: [8]c.VkImage,
  views: [8]c.VkImageView,
  framebuffers: [8]c.VkFramebuffer,
  depth_img: c.VkImage,
  depth_mem: c.VkDeviceMemory,
  depth_view: c.VkImageView,
  render_pass: c.VkRenderPass,
  frame_pool: c.VkCommandPool, // separate from cmd_pool (compute resets that one)
  img_avail: [FRAMES]c.VkSemaphore,
  render_done: [FRAMES]c.VkSemaphore,
  in_flight: [FRAMES]c.VkFence,
  frame_cmd: [FRAMES]c.VkCommandBuffer,
  frame: u32, // frame-in-flight index (0..FRAMES-1)
  img_index: u32, // acquired swapchain image for the current frame
  // per-draw mesh uniform block (@group(0) binding 0): one pool+buffer per frame
  mesh_dsl: c.VkDescriptorSetLayout,
  mesh_upool: [FRAMES]c.VkDescriptorPool,
  mesh_ubuf: [FRAMES]Buffer,
  mesh_uslot: [FRAMES]u32,
  // 2-D fill pipeline (fill.vert/frag) + its 6-binding set + dummy texture
  fill_dsl: c.VkDescriptorSetLayout,
  fill_pipe: c.VkPipeline,
  fill_layout: c.VkPipelineLayout,
  fill_vmod: c.VkShaderModule,
  fill_fmod: c.VkShaderModule,
  dummy_img: c.VkImage,
  dummy_mem: c.VkDeviceMemory,
  dummy_view: c.VkImageView,
  dummy_sampler: c.VkSampler,
  view_ubuf: [FRAMES]Buffer, // viewSize, per frame
  frag_ubuf: [FRAMES]Buffer, // per-draw frag uniform ring
  fill_upool: [FRAMES]c.VkDescriptorPool,
  fill_uslot: [FRAMES]u32,
  pull_upool: [FRAMES]c.VkDescriptorPool, // per-frame storage-buffer sets for vertex-pull draws
  tex_upool: [FRAMES]c.VkDescriptorPool, // per-draw @group(1) texture sets

  // Query Caps from the live physical device (cheap; no state kept).
  pub fn queryCaps(self: *Vk) Caps {
    // properties2 chain: subgroup properties (core 1.1)
    var sub = c.VkPhysicalDeviceSubgroupProperties{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES };
    var p2 = c.VkPhysicalDeviceProperties2{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = @ptrCast(&sub) };
    vkGetPhysicalDeviceProperties2(self.pdev, &p2);

    // VK_EXT_shader_atomic_float joins the features chain only when the device
    // lists it (querying an unknown struct is undefined behaviour per spec).
    var has_af = false;
    var next: u32 = 0;
    _ = vkEnumerateDeviceExtensionProperties(self.pdev, null, &next, null);
    var exts: [256]c.VkExtensionProperties = undefined;
    if (next > exts.len) next = exts.len;
    _ = vkEnumerateDeviceExtensionProperties(self.pdev, null, &next, &exts);
    for (exts[0..next]) |e| {
      if (std.mem.eql(u8, std.mem.sliceTo(&e.extensionName, 0), "VK_EXT_shader_atomic_float")) has_af = true;
    }
    var af = c.VkPhysicalDeviceShaderAtomicFloatFeaturesEXT{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT };
    var v12 = c.VkPhysicalDeviceVulkan12Features{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = if (has_af) @as(?*anyopaque, @ptrCast(&af)) else null };
    var f2 = c.VkPhysicalDeviceFeatures2{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = @ptrCast(&v12) };
    vkGetPhysicalDeviceFeatures2(self.pdev, &f2);

    var props: c.VkPhysicalDeviceProperties = undefined;
    vkGetPhysicalDeviceProperties(self.pdev, &props);
    return .{
      .api_major = (props.apiVersion >> 22) & 0x7f,
      .api_minor = (props.apiVersion >> 12) & 0x3ff,
      .subgroup_size = sub.subgroupSize,
      .sg_arith = (sub.supportedOperations & c.VK_SUBGROUP_FEATURE_ARITHMETIC_BIT) != 0,
      .sg_ballot = (sub.supportedOperations & c.VK_SUBGROUP_FEATURE_BALLOT_BIT) != 0,
      .sg_shuffle = (sub.supportedOperations & c.VK_SUBGROUP_FEATURE_SHUFFLE_BIT) != 0,
      .desc_index = v12.descriptorIndexing != 0,
      .runtime_array = v12.runtimeDescriptorArray != 0,
      .bda = v12.bufferDeviceAddress != 0,
      .f16 = v12.shaderFloat16 != 0,
      .atomic_fadd = has_af and af.shaderBufferFloat32AtomicAdd != 0,
    };
  }

  pub fn init() Error!Vk {
    var self: Vk = undefined;

    // --- instance (direct MoltenVK link: no loader, no portability enumeration) ---
    const app = c.VkApplicationInfo{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "ink-gpu", .apiVersion = c.VK_API_VERSION_1_2 };
    const ici = c.VkInstanceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    if (!ok(vkCreateInstance(&ici, null, &self.instance))) return Error.VulkanInit;

    var ndev: u32 = 0;
    if (!ok(vkEnumeratePhysicalDevices(self.instance, &ndev, null)) or ndev == 0) return Error.NoDevice;
    var devs: [8]c.VkPhysicalDevice = undefined;
    ndev = @min(ndev, 8);
    _ = vkEnumeratePhysicalDevices(self.instance, &ndev, &devs);
    self.pdev = devs[0];

    // --- compute queue family ---
    var nqf: u32 = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(self.pdev, &nqf, null);
    var qfs: [16]c.VkQueueFamilyProperties = undefined;
    nqf = @min(nqf, 16);
    vkGetPhysicalDeviceQueueFamilyProperties(self.pdev, &nqf, &qfs);
    self.qfam = 0;
    var found = false;
    { var i: u32 = 0; while (i < nqf) : (i += 1) { if (qfs[i].queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) { self.qfam = i; found = true; break; } } }
    if (!found) return Error.NoDevice;

    // --- host-visible|coherent memory type (unified memory on Apple) ---
    var mp: c.VkPhysicalDeviceMemoryProperties = undefined;
    vkGetPhysicalDeviceMemoryProperties(self.pdev, &mp);
    const want = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    self.memtype = 0;
    var mfound = false;
    { var i: u32 = 0; while (i < mp.memoryTypeCount) : (i += 1) { if (mp.memoryTypes[i].propertyFlags & want == want) { self.memtype = i; mfound = true; break; } } }
    if (!mfound) return Error.VulkanInit;

    // --- logical device (portability_subset + queried features) ---
    // The kk backend needs the caps it schedules around actually ENABLED, not
    // just queried: subgroup arithmetic is core 1.1, but float atomics
    // (§7 scatter-add) and descriptor indexing (bindless) are opt-in features
    // chained into pNext, and atomic-float also needs its EXT in the ext list.
    const caps = self.queryCaps();
    var feat = enabledFeatures(caps);
    feat.link(); // fix pNext self-pointers after the by-value return
    var dev_exts: [4][*c]const u8 = undefined;
    var n_exts: u32 = 0;
    dev_exts[n_exts] = "VK_KHR_portability_subset"; n_exts += 1;
    if (caps.atomic_fadd) { dev_exts[n_exts] = "VK_EXT_shader_atomic_float"; n_exts += 1; }
    const prio: f32 = 1.0;
    const qci = c.VkDeviceQueueCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = self.qfam, .queueCount = 1, .pQueuePriorities = &prio };
    const dci = c.VkDeviceCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &feat.f2,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
      .enabledExtensionCount = n_exts,
      .ppEnabledExtensionNames = &dev_exts,
    };
    if (!ok(vkCreateDevice(self.pdev, &dci, null, &self.dev))) return Error.VulkanInit;
    vkGetDeviceQueue(self.dev, self.qfam, 0, &self.queue);

    // --- command pool (transient; buffers allocated per op, pool reset in bulk) ---
    const cpci = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT, .queueFamilyIndex = self.qfam };
    if (!ok(vkCreateCommandPool(self.dev, &cpci, null, &self.cmd_pool))) return Error.VulkanInit;

    // --- descriptor pool (bulk-reset per batch; POOL_SETS sets, ≤MAX_BIND each) ---
    const sizes = [_]c.VkDescriptorPoolSize{
      .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = POOL_SETS * MAX_BIND },
      .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = POOL_SETS },
    };
    const dpci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = POOL_SETS, .poolSizeCount = sizes.len, .pPoolSizes = &sizes };
    if (!ok(vkCreateDescriptorPool(self.dev, &dpci, null, &self.desc_pool))) return Error.VulkanInit;

    self.recording = false;
    self.nsets = 0;
    self.windowed = false;
    return self;
  }

  pub fn deinit(self: *Vk) void {
    self.sync();
    _ = vkDeviceWaitIdle(self.dev);
    if (self.windowed) {
      var i: u32 = 0;
      while (i < FRAMES) : (i += 1) {
        vkDestroySemaphore(self.dev, self.img_avail[i], null);
        vkDestroySemaphore(self.dev, self.render_done[i], null);
        vkDestroyFence(self.dev, self.in_flight[i], null);
        vkDestroyDescriptorPool(self.dev, self.mesh_upool[i], null);
        self.destroyBuffer(self.mesh_ubuf[i]);
        vkDestroyDescriptorPool(self.dev, self.fill_upool[i], null);
        vkDestroyDescriptorPool(self.dev, self.tex_upool[i], null);
        vkDestroyDescriptorPool(self.dev, self.pull_upool[i], null);
        self.destroyBuffer(self.view_ubuf[i]);
        self.destroyBuffer(self.frag_ubuf[i]);
      }
      vkDestroyDescriptorSetLayout(self.dev, self.mesh_dsl, null);
      vkDestroyPipeline(self.dev, self.fill_pipe, null);
      vkDestroyPipelineLayout(self.dev, self.fill_layout, null);
      vkDestroyDescriptorSetLayout(self.dev, self.fill_dsl, null);
      vkDestroyShaderModule(self.dev, self.fill_vmod, null);
      vkDestroyShaderModule(self.dev, self.fill_fmod, null);
      vkDestroySampler(self.dev, self.dummy_sampler, null);
      vkDestroyImageView(self.dev, self.dummy_view, null);
      vkDestroyImage(self.dev, self.dummy_img, null);
      vkFreeMemory(self.dev, self.dummy_mem, null);
      self.destroySwapObjects();
      vkDestroyRenderPass(self.dev, self.render_pass, null);
      vkDestroyCommandPool(self.dev, self.frame_pool, null);
      vkDestroySwapchainKHR(self.dev, self.swapchain, null);
      vkDestroySurfaceKHR(self.instance, self.surface, null);
    }
    vkDestroyDescriptorPool(self.dev, self.desc_pool, null);
    vkDestroyCommandPool(self.dev, self.cmd_pool, null);
    vkDestroyDevice(self.dev, null);
    vkDestroyInstance(self.instance, null);
  }

  // Windowed context: instance(+surface exts) → surface(callback) → device(+swapchain,
  // present queue) → render pass → swapchain/views/framebuffers → frame sync. Shares
  // the same compute path (createBuffer/dispatch/sync) so the frame callback can run
  // compute exactly as headless does.
  pub fn initWindowed(window: *anyopaque, w: u32, h: u32) Error!Vk {
    var self: Vk = undefined;

    const inst_exts = [_][*c]const u8{ "VK_KHR_surface", "VK_EXT_metal_surface" };
    const app = c.VkApplicationInfo{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "ink-gpu", .apiVersion = c.VK_API_VERSION_1_2 };
    const ici = c.VkInstanceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = inst_exts.len, .ppEnabledExtensionNames = &inst_exts };
    if (!ok(vkCreateInstance(&ici, null, &self.instance))) return Error.VulkanInit;

    self.surface = null;
    if (!ok(glfwCreateWindowSurface(self.instance, window, null, &self.surface)) or self.surface == null) return Error.VulkanInit;

    var ndev: u32 = 0;
    if (!ok(vkEnumeratePhysicalDevices(self.instance, &ndev, null)) or ndev == 0) return Error.NoDevice;
    var devs: [8]c.VkPhysicalDevice = undefined;
    ndev = @min(ndev, 8);
    _ = vkEnumeratePhysicalDevices(self.instance, &ndev, &devs);
    self.pdev = devs[0];

    // queue family with graphics+compute and present support
    var nqf: u32 = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(self.pdev, &nqf, null);
    var qfs: [16]c.VkQueueFamilyProperties = undefined;
    nqf = @min(nqf, 16);
    vkGetPhysicalDeviceQueueFamilyProperties(self.pdev, &nqf, &qfs);
    self.qfam = 0;
    var found = false;
    {
      var i: u32 = 0;
      while (i < nqf) : (i += 1) {
        const gc = qfs[i].queueFlags & (c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT);
        var present: c.VkBool32 = 0;
        _ = vkGetPhysicalDeviceSurfaceSupportKHR(self.pdev, i, self.surface, &present);
        if (gc == (c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT) and present != 0) { self.qfam = i; found = true; break; }
      }
    }
    if (!found) return Error.NoDevice;

    var mp: c.VkPhysicalDeviceMemoryProperties = undefined;
    vkGetPhysicalDeviceMemoryProperties(self.pdev, &mp);
    const want = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    self.memtype = 0;
    { var i: u32 = 0; while (i < mp.memoryTypeCount) : (i += 1) { if (mp.memoryTypes[i].propertyFlags & want == want) { self.memtype = i; break; } } }

    const caps = self.queryCaps();
    var feat = enabledFeatures(caps);
    feat.link(); // fix pNext self-pointers after the by-value return
    var dev_exts: [4][*c]const u8 = undefined;
    var n_exts: u32 = 0;
    dev_exts[n_exts] = "VK_KHR_swapchain"; n_exts += 1;
    dev_exts[n_exts] = "VK_KHR_portability_subset"; n_exts += 1;
    if (caps.atomic_fadd) { dev_exts[n_exts] = "VK_EXT_shader_atomic_float"; n_exts += 1; }
    const prio: f32 = 1.0;
    const qci = c.VkDeviceQueueCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = self.qfam, .queueCount = 1, .pQueuePriorities = &prio };
    const dci = c.VkDeviceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &feat.f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = n_exts, .ppEnabledExtensionNames = &dev_exts };
    if (!ok(vkCreateDevice(self.pdev, &dci, null, &self.dev))) return Error.VulkanInit;
    vkGetDeviceQueue(self.dev, self.qfam, 0, &self.queue);

    // compute pools (same as headless)
    const cpci = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT, .queueFamilyIndex = self.qfam };
    if (!ok(vkCreateCommandPool(self.dev, &cpci, null, &self.cmd_pool))) return Error.VulkanInit;
    const sizes = [_]c.VkDescriptorPoolSize{
      .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = POOL_SETS * MAX_BIND },
      .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = POOL_SETS },
    };
    const dpci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = POOL_SETS, .poolSizeCount = sizes.len, .pPoolSizes = &sizes };
    if (!ok(vkCreateDescriptorPool(self.dev, &dpci, null, &self.desc_pool))) return Error.VulkanInit;
    self.recording = false;
    self.nsets = 0;

    // surface format (prefer BGRA8_UNORM, matching the Dawn swapchain)
    var nfmt: u32 = 0;
    _ = vkGetPhysicalDeviceSurfaceFormatsKHR(self.pdev, self.surface, &nfmt, null);
    var fmts: [32]c.VkSurfaceFormatKHR = undefined;
    nfmt = @min(nfmt, 32);
    _ = vkGetPhysicalDeviceSurfaceFormatsKHR(self.pdev, self.surface, &nfmt, &fmts);
    self.swap_format = fmts[0].format;
    var colorspace = fmts[0].colorSpace;
    { var i: u32 = 0; while (i < nfmt) : (i += 1) { if (fmts[i].format == c.VK_FORMAT_B8G8R8A8_UNORM) { self.swap_format = fmts[i].format; colorspace = fmts[i].colorSpace; break; } } }

    // render pass: color (clear→present) + depth (clear, D32); the 2-D fill layer
    // draws with depth-test off, the mesh layer with depth-test on.
    const atts = [2]c.VkAttachmentDescription{
      .{
        .format = self.swap_format, .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      },
      .{
        .format = c.VK_FORMAT_D32_SFLOAT, .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      },
    };
    const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    const depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    const subpass = c.VkSubpassDescription{ .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &color_ref, .pDepthStencilAttachment = &depth_ref };
    const dep = c.VkSubpassDependency{
      .srcSubpass = c.VK_SUBPASS_EXTERNAL,
      .dstSubpass = 0,
      .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
      .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
      .srcAccessMask = 0,
      .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };
    const rpci = c.VkRenderPassCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = &atts, .subpassCount = 1, .pSubpasses = &subpass, .dependencyCount = 1, .pDependencies = &dep };
    if (!ok(vkCreateRenderPass(self.dev, &rpci, null, &self.render_pass))) return Error.VulkanInit;

    self.swap_colorspace = colorspace;

    // frame command pool + per-frame command buffers + sync objects
    const fpci = c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = self.qfam };
    if (!ok(vkCreateCommandPool(self.dev, &fpci, null, &self.frame_pool))) return Error.VulkanInit;
    const fcbai = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = self.frame_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = FRAMES };
    if (!ok(vkAllocateCommandBuffers(self.dev, &fcbai, &self.frame_cmd[0]))) return Error.VulkanInit;
    {
      var i: u32 = 0;
      while (i < FRAMES) : (i += 1) {
        const sci = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        const fci = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = c.VK_FENCE_CREATE_SIGNALED_BIT };
        _ = vkCreateSemaphore(self.dev, &sci, null, &self.img_avail[i]);
        _ = vkCreateSemaphore(self.dev, &sci, null, &self.render_done[i]);
        _ = vkCreateFence(self.dev, &fci, null, &self.in_flight[i]);
      }
    }

    // per-draw mesh uniform block: DSL (binding 0, uniform, vertex+fragment) +
    // one descriptor pool & host-visible uniform buffer per frame in flight.
    const ubind = c.VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT };
    const udsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &ubind };
    if (!ok(vkCreateDescriptorSetLayout(self.dev, &udsli, null, &self.mesh_dsl))) return Error.VulkanInit;
    {
      var i: u32 = 0;
      while (i < FRAMES) : (i += 1) {
        const usz = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = MAX_MCALLS };
        const updci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = MAX_MCALLS, .poolSizeCount = 1, .pPoolSizes = &usz };
        _ = vkCreateDescriptorPool(self.dev, &updci, null, &self.mesh_upool[i]);
        self.mesh_ubuf[i] = self.createBuffer(MAX_MCALLS * UNI_SLOT, true) catch return Error.VulkanInit;
        self.mesh_uslot[i] = 0;
        // per-frame storage-buffer sets for vertex-pull draws (kk2 §5)
        const psz = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = MAX_MCALLS * MAX_BIND };
        const ppci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = MAX_MCALLS, .poolSizeCount = 1, .pPoolSizes = &psz };
        _ = vkCreateDescriptorPool(self.dev, &ppci, null, &self.pull_upool[i]);
      }
    }

    self.setupFill() catch return Error.VulkanInit;

    self.frame = 0;
    self.windowed = true;
    self.createSwapObjects(w, h);
    return self;
  }

  // Build the 2-D fill pipeline (fill.vert/frag SPIR-V), its 6-binding descriptor
  // set layout, a 1×1 dummy texture+sampler (for the texture bindings on non-image
  // fills), and per-frame view/frag uniform buffers + descriptor pools.
  fn setupFill(self: *Vk) Error!void {
    // 6-binding DSL: view(u) frag(u) tex(img) samp colormap(img) samp
    const fb = [6]c.VkDescriptorSetLayoutBinding{
      .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT },
      .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
      .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
      .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
      .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
      .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    const dsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 6, .pBindings = &fb };
    if (!ok(vkCreateDescriptorSetLayout(self.dev, &dsli, null, &self.fill_dsl))) return Error.VulkanInit;

    // shader modules from the GLSL→SPIR-V bridge output
    const vspv align(4) = @embedFile("fill.vert.spv").*;
    const fspv align(4) = @embedFile("fill.frag.spv").*;
    const vsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = vspv.len, .pCode = @ptrCast(&vspv) };
    if (!ok(vkCreateShaderModule(self.dev, &vsmi, null, &self.fill_vmod))) return Error.VulkanInit;
    const fsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = fspv.len, .pCode = @ptrCast(&fspv) };
    if (!ok(vkCreateShaderModule(self.dev, &fsmi, null, &self.fill_fmod))) return Error.VulkanInit;

    const plci = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &self.fill_dsl };
    if (!ok(vkCreatePipelineLayout(self.dev, &plci, null, &self.fill_layout))) return Error.VulkanInit;

    self.fill_pipe = self.buildFillPipe(self.fill_fmod) orelse return Error.VulkanInit;

    // 1×1 dummy texture (never sampled on solid/gradient fills; just satisfies the
    // layout). Transitioned UNDEFINED→SHADER_READ_ONLY via a one-time submit.
    const ici = c.VkImageCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = c.VK_IMAGE_TYPE_2D, .format = c.VK_FORMAT_R8G8B8A8_UNORM,
      .extent = .{ .width = 1, .height = 1, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = c.VK_SAMPLE_COUNT_1_BIT,
      .tiling = c.VK_IMAGE_TILING_OPTIMAL, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (!ok(vkCreateImage(self.dev, &ici, null, &self.dummy_img))) return Error.VulkanInit;
    var req: c.VkMemoryRequirements = undefined;
    vkGetImageMemoryRequirements(self.dev, self.dummy_img, &req);
    const ai = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = self.memtype };
    _ = vkAllocateMemory(self.dev, &ai, null, &self.dummy_mem);
    _ = vkBindImageMemory(self.dev, self.dummy_img, self.dummy_mem, 0);
    const ivci = c.VkImageViewCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = self.dummy_img, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .components = .{}, .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
    _ = vkCreateImageView(self.dev, &ivci, null, &self.dummy_view);
    const smci = c.VkSamplerCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = c.VK_FILTER_LINEAR, .minFilter = c.VK_FILTER_LINEAR, .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 1.0 };
    _ = vkCreateSampler(self.dev, &smci, null, &self.dummy_sampler);
    // one-time layout transition
    {
      var tcb: c.VkCommandBuffer = undefined;
      const cbai = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = self.cmd_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
      _ = vkAllocateCommandBuffers(self.dev, &cbai, &tcb);
      const bi = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      _ = vkBeginCommandBuffer(tcb, &bi);
      const bar = c.VkImageMemoryBarrier{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT, .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .image = self.dummy_img, .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
      vkCmdPipelineBarrier(tcb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&bar));
      _ = vkEndCommandBuffer(tcb);
      const si = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&tcb) };
      _ = vkQueueSubmit(self.queue, 1, @ptrCast(&si), null);
      _ = vkQueueWaitIdle(self.queue);
      _ = vkResetCommandPool(self.dev, self.cmd_pool, 0);
    }

    // per-frame view uniform + frag ring + descriptor pool
    var i: u32 = 0;
    while (i < FRAMES) : (i += 1) {
      self.view_ubuf[i] = try self.createBuffer(UNI_SLOT, true);
      self.frag_ubuf[i] = try self.createBuffer(MAX_MCALLS * UNI_SLOT, true);
      const ps = [3]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 2 * MAX_MCALLS },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 2 * MAX_MCALLS },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 2 * MAX_MCALLS },
      };
      const dpci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = MAX_MCALLS, .poolSizeCount = 3, .pPoolSizes = &ps };
      _ = vkCreateDescriptorPool(self.dev, &dpci, null, &self.fill_upool[i]);
      self.fill_uslot[i] = 0;
      // texture @group(1) sets: up to 256 draws × (MAX_BIND images + 1 sampler)
      const tps = [2]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 256 * MAX_BIND },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 256 },
      };
      const tdpci = c.VkDescriptorPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 256, .poolSizeCount = 2, .pPoolSizes = &tps };
      _ = vkCreateDescriptorPool(self.dev, &tdpci, null, &self.tex_upool[i]);
    }
  }

  // Allocate a @group(1) descriptor set binding `texs` (n sampled images + one
  // shared sampler) for pipeline `mp`, from the current frame's texture pool.
  pub fn texSet(self: *Vk, mp: MeshPipe, texs: []const Texture) c.VkDescriptorSet {
    if (mp.n_tex == 0 or texs.len == 0) return null;
    var set: c.VkDescriptorSet = undefined;
    const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.tex_upool[self.frame], .descriptorSetCount = 1, .pSetLayouts = &mp.tex_dsl };
    if (!ok(vkAllocateDescriptorSets(self.dev, &dsai, &set))) return null;
    var imgs: [MAX_BIND]c.VkDescriptorImageInfo = undefined;
    var writes: [MAX_BIND + 1]c.VkWriteDescriptorSet = undefined;
    var i: u32 = 0;
    while (i < mp.n_tex) : (i += 1) {
      const ti = if (i < texs.len) i else 0;
      imgs[i] = .{ .imageView = texs[ti].view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
      writes[i] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = i, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &imgs[i] };
    }
    const smp = c.VkDescriptorImageInfo{ .sampler = texs[0].sampler };
    writes[mp.n_tex] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = mp.n_tex, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = &smp };
    vkUpdateDescriptorSets(self.dev, mp.n_tex + 1, &writes, 0, null);
    return set;
  }

  // Graphics pipeline: fill vertex shader + given fragment module, [vec2 pos, vec2
  // uv] stride-16 vertices, no depth, alpha blend, dynamic viewport/scissor.
  fn buildFillPipe(self: *Vk, fmod: c.VkShaderModule) ?c.VkPipeline {
    const stages = [2]c.VkPipelineShaderStageCreateInfo{
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = self.fill_vmod, .pName = "main" },
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fmod, .pName = "main" },
    };
    const vattrs = [2]c.VkVertexInputAttributeDescription{
      .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
      .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
    };
    const vbind = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 16, .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    const vin = c.VkPipelineVertexInputStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vbind, .vertexAttributeDescriptionCount = 2, .pVertexAttributeDescriptions = &vattrs };
    const ia = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    const vps = c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    const rs = c.VkPipelineRasterizationStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = c.VK_POLYGON_MODE_FILL, .cullMode = c.VK_CULL_MODE_NONE, .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0 };
    const mss = c.VkPipelineMultisampleStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
    const ds = c.VkPipelineDepthStencilStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = c.VK_FALSE, .depthWriteEnable = c.VK_FALSE, .depthCompareOp = c.VK_COMPARE_OP_ALWAYS };
    const cba = c.VkPipelineColorBlendAttachmentState{
      .blendEnable = c.VK_TRUE,
      .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .colorBlendOp = c.VK_BLEND_OP_ADD,
      .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = c.VK_BLEND_OP_ADD,
      .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const cb = c.VkPipelineColorBlendStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba };
    const dyn_states = [2]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dyn = c.VkPipelineDynamicStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };
    const gpci = c.VkGraphicsPipelineCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2, .pStages = &stages,
      .pVertexInputState = &vin, .pInputAssemblyState = &ia, .pViewportState = &vps,
      .pRasterizationState = &rs, .pMultisampleState = &mss, .pDepthStencilState = &ds,
      .pColorBlendState = &cb, .pDynamicState = &dyn,
      .layout = self.fill_layout, .renderPass = self.render_pass, .subpass = 0, .basePipelineIndex = -1,
    };
    var pipe: c.VkPipeline = undefined;
    if (!ok(vkCreateGraphicsPipelines(self.dev, null, 1, @ptrCast(&gpci), null, @ptrCast(&pipe)))) return null;
    return pipe;
  }

  // Custom fragment (user SPIR-V from dye.k) over the fill vertex shader. Reuses
  // the fill layout, so the shader may read the frag uniform/textures or nothing.
  pub const FillPipe = struct { pipe: c.VkPipeline, fmod: c.VkShaderModule };
  pub fn createFillShaderPipe(self: *Vk, frag: []const u32) ?FillPipe {
    var fmod: c.VkShaderModule = undefined;
    const smi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = frag.len * 4, .pCode = frag.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &smi, null, &fmod))) return null;
    const pipe = self.buildFillPipe(fmod) orelse { vkDestroyShaderModule(self.dev, fmod, null); return null; };
    return .{ .pipe = pipe, .fmod = fmod };
  }
  pub fn destroyFillShaderPipe(self: *Vk, fp: FillPipe) void {
    vkDestroyPipeline(self.dev, fp.pipe, null);
    vkDestroyShaderModule(self.dev, fp.fmod, null);
  }

  // Reserve a per-draw fill descriptor set: view uniform (viewSize), frag uniform
  // slot (44 floats), and the dummy texture/sampler bindings.
  pub fn fillSet(self: *Vk, vw: f32, vh: f32, frag: []const f32) c.VkDescriptorSet {
    const f = self.frame;
    const slot = self.fill_uslot[f];
    if (slot >= MAX_MCALLS) return null;
    self.fill_uslot[f] = slot + 1;
    // view (write every draw; cheap)
    const view = [4]f32{ vw, vh, 0, 0 };
    @memcpy(self.view_ubuf[f].mapped[0..16], std.mem.sliceAsBytes(view[0..]));
    // frag slot
    const off: usize = @as(usize, slot) * UNI_SLOT;
    const n = @min(frag.len, @as(usize, 44));
    const src = std.mem.sliceAsBytes(frag[0..n]);
    @memcpy(self.frag_ubuf[f].mapped[off..][0..src.len], src);

    var set: c.VkDescriptorSet = undefined;
    const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.fill_upool[f], .descriptorSetCount = 1, .pSetLayouts = &self.fill_dsl };
    if (!ok(vkAllocateDescriptorSets(self.dev, &dsai, &set))) return null;
    const vi = c.VkDescriptorBufferInfo{ .buffer = self.view_ubuf[f].buf, .offset = 0, .range = 16 };
    const fi = c.VkDescriptorBufferInfo{ .buffer = self.frag_ubuf[f].buf, .offset = off, .range = 176 };
    const img = c.VkDescriptorImageInfo{ .imageView = self.dummy_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    const smp = c.VkDescriptorImageInfo{ .sampler = self.dummy_sampler };
    const writes = [6]c.VkWriteDescriptorSet{
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &vi },
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &fi },
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 2, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &img },
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 3, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = &smp },
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 4, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &img },
      .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 5, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = &smp },
    };
    vkUpdateDescriptorSets(self.dev, 6, &writes, 0, null);
    return set;
  }

  // Record a 2-D fill draw (no depth) into the render-pass command buffer. `pipe`
  // null → the built-in fill pipeline; else a custom fill-shader pipeline.
  pub fn drawFill(self: *Vk, cb: c.VkCommandBuffer, vbuf: Buffer, byte_offset: u64, vcount: u32, set: c.VkDescriptorSet, pipe: c.VkPipeline) void {
    const off: c.VkDeviceSize = byte_offset;
    vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (pipe != null) pipe else self.fill_pipe);
    vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.fill_layout, 0, 1, @ptrCast(&set), 0, null);
    vkCmdBindVertexBuffers(cb, 0, 1, @ptrCast(&vbuf.buf), @ptrCast(&off));
    vkCmdDraw(cb, vcount, 1, 0, 0);
  }

  pub fn nullPipe() c.VkPipeline {
    return null;
  }
  pub fn nullSet() c.VkDescriptorSet {
    return null;
  }

  // Reserve a per-draw uniform slot in the current frame's buffer, upload `floats`,
  // and return a descriptor set bound to it (for a has_uniform mesh pipeline).
  pub fn meshUniformSet(self: *Vk, floats: []const f32) c.VkDescriptorSet {
    const f = self.frame;
    const slot = self.mesh_uslot[f];
    if (slot >= MAX_MCALLS) return null;
    self.mesh_uslot[f] = slot + 1;
    const off: usize = @as(usize, slot) * UNI_SLOT;
    const n = @min(floats.len, @as(usize, MESH_UNI_FLOATS));
    const src = std.mem.sliceAsBytes(floats[0..n]);
    @memcpy(self.mesh_ubuf[f].mapped[off..][0..src.len], src);
    var set: c.VkDescriptorSet = undefined;
    const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.mesh_upool[f], .descriptorSetCount = 1, .pSetLayouts = &self.mesh_dsl };
    if (!ok(vkAllocateDescriptorSets(self.dev, &dsai, &set))) return null;
    const binfo = c.VkDescriptorBufferInfo{ .buffer = self.mesh_ubuf[f].buf, .offset = off, .range = UNI_SLOT };
    const wr = c.VkWriteDescriptorSet{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &binfo };
    vkUpdateDescriptorSets(self.dev, 1, @ptrCast(&wr), 0, null);
    return set;
  }

  fn createSwapObjects(self: *Vk, w: u32, h: u32) void {
    var caps: c.VkSurfaceCapabilitiesKHR = undefined;
    _ = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface, &caps);
    if (caps.currentExtent.width != 0xFFFFFFFF) {
      self.swap_extent = caps.currentExtent;
    } else {
      self.swap_extent = .{
        .width = std.math.clamp(w, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(h, caps.minImageExtent.height, caps.maxImageExtent.height),
      };
    }
    var want_n = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 and want_n > caps.maxImageCount) want_n = caps.maxImageCount;

    const scci = c.VkSwapchainCreateInfoKHR{
      .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
      .surface = self.surface,
      .minImageCount = want_n,
      .imageFormat = self.swap_format,
      .imageColorSpace = self.swap_colorspace,
      .imageExtent = self.swap_extent,
      .imageArrayLayers = 1,
      .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
      .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
      .preTransform = caps.currentTransform,
      .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
      .presentMode = c.VK_PRESENT_MODE_FIFO_KHR, // always available
      .clipped = c.VK_TRUE,
    };
    _ = vkCreateSwapchainKHR(self.dev, &scci, null, &self.swapchain);

    // depth image sized to the extent (any memory type — MoltenVK is unified)
    const dici = c.VkImageCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = c.VK_IMAGE_TYPE_2D,
      .format = c.VK_FORMAT_D32_SFLOAT,
      .extent = .{ .width = self.swap_extent.width, .height = self.swap_extent.height, .depth = 1 },
      .mipLevels = 1, .arrayLayers = 1,
      .samples = c.VK_SAMPLE_COUNT_1_BIT,
      .tiling = c.VK_IMAGE_TILING_OPTIMAL,
      .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
      .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    _ = vkCreateImage(self.dev, &dici, null, &self.depth_img);
    var dreq: c.VkMemoryRequirements = undefined;
    vkGetImageMemoryRequirements(self.dev, self.depth_img, &dreq);
    const dai = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = dreq.size, .memoryTypeIndex = self.memtype };
    _ = vkAllocateMemory(self.dev, &dai, null, &self.depth_mem);
    _ = vkBindImageMemory(self.dev, self.depth_img, self.depth_mem, 0);
    const dvci = c.VkImageViewCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = self.depth_img, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .format = c.VK_FORMAT_D32_SFLOAT, .components = .{},
      .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    _ = vkCreateImageView(self.dev, &dvci, null, &self.depth_view);

    self.n_images = 0;
    _ = vkGetSwapchainImagesKHR(self.dev, self.swapchain, &self.n_images, null);
    self.n_images = @min(self.n_images, 8);
    _ = vkGetSwapchainImagesKHR(self.dev, self.swapchain, &self.n_images, &self.images);

    var i: u32 = 0;
    while (i < self.n_images) : (i += 1) {
      const ivci = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self.images[i],
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = self.swap_format,
        .components = .{},
        .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
      };
      _ = vkCreateImageView(self.dev, &ivci, null, &self.views[i]);
      const fb_atts = [2]c.VkImageView{ self.views[i], self.depth_view };
      const fbci = c.VkFramebufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = self.render_pass,
        .attachmentCount = 2,
        .pAttachments = &fb_atts,
        .width = self.swap_extent.width,
        .height = self.swap_extent.height,
        .layers = 1,
      };
      _ = vkCreateFramebuffer(self.dev, &fbci, null, &self.framebuffers[i]);
    }
  }

  fn destroySwapObjects(self: *Vk) void {
    vkDestroyImageView(self.dev, self.depth_view, null);
    vkDestroyImage(self.dev, self.depth_img, null);
    vkFreeMemory(self.dev, self.depth_mem, null);
    var i: u32 = 0;
    while (i < self.n_images) : (i += 1) {
      vkDestroyFramebuffer(self.dev, self.framebuffers[i], null);
      vkDestroyImageView(self.dev, self.views[i], null);
    }
  }

  fn recreateSwapchain(self: *Vk, w: u32, h: u32) void {
    _ = vkDeviceWaitIdle(self.dev);
    self.destroySwapObjects();
    vkDestroySwapchainKHR(self.dev, self.swapchain, null);
    self.createSwapObjects(w, h);
  }

  // Acquire an image and begin a clear render pass; returns the frame command
  // buffer to draw into, or null if the swapchain needs recreation (skip frame).
  pub fn beginFrame(self: *Vk, w: u32, h: u32, clear: [4]f32) ?c.VkCommandBuffer {
    _ = vkWaitForFences(self.dev, 1, @ptrCast(&self.in_flight[self.frame]), c.VK_TRUE, ~@as(u64, 0));
    const acq = vkAcquireNextImageKHR(self.dev, self.swapchain, ~@as(u64, 0), self.img_avail[self.frame], null, &self.img_index);
    if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) { self.recreateSwapchain(w, h); return null; }
    _ = vkResetFences(self.dev, 1, @ptrCast(&self.in_flight[self.frame]));
    // this frame's prior uniform sets are done (fence waited) — recycle them
    _ = vkResetDescriptorPool(self.dev, self.mesh_upool[self.frame], 0);
    self.mesh_uslot[self.frame] = 0;
    _ = vkResetDescriptorPool(self.dev, self.fill_upool[self.frame], 0);
    self.fill_uslot[self.frame] = 0;
    _ = vkResetDescriptorPool(self.dev, self.tex_upool[self.frame], 0);
    _ = vkResetDescriptorPool(self.dev, self.pull_upool[self.frame], 0);

    const cb = self.frame_cmd[self.frame];
    const bi = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    _ = vkBeginCommandBuffer(cb, &bi);
    const cvs = [2]c.VkClearValue{
      .{ .color = .{ .float32 = clear } },
      .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
    };
    const rpbi = c.VkRenderPassBeginInfo{
      .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
      .renderPass = self.render_pass,
      .framebuffer = self.framebuffers[self.img_index],
      .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swap_extent },
      .clearValueCount = 2,
      .pClearValues = &cvs,
    };
    vkCmdBeginRenderPass(cb, &rpbi, c.VK_SUBPASS_CONTENTS_INLINE);
    // dynamic viewport+scissor so pipelines are resize-independent.
    // NEGATIVE height (base at y=h, core since Vulkan 1.1/Maintenance1): Vulkan's
    // NDC is Y-down while every shader in the tree (dye output + fill.vert) was
    // authored for WebGPU/GL Y-up NDC — without the flip the whole frame renders
    // vertically mirrored (upside-down earth/text; caught 2026-07-15, the
    // migration-era "identical" snapshot stats were flip-blind). Cull is NONE in
    // both pipelines, so the winding inversion is harmless.
    const fh: f32 = @floatFromInt(self.swap_extent.height);
    const vp = c.VkViewport{ .x = 0, .y = fh, .width = @floatFromInt(self.swap_extent.width), .height = -fh, .minDepth = 0, .maxDepth = 1 };
    const sc = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swap_extent };
    vkCmdSetViewport(cb, 0, 1, @ptrCast(&vp));
    vkCmdSetScissor(cb, 0, 1, @ptrCast(&sc));
    return cb;
  }

  pub fn waitIdle(self: *Vk) void {
    _ = vkDeviceWaitIdle(self.dev);
  }

  pub fn extent(self: *Vk) [2]u32 {
    return .{ self.swap_extent.width, self.swap_extent.height };
  }

  // Copy the just-rendered swapchain image into a host-visible buffer (for -snap).
  // Records into the still-open frame command buffer between the render pass and
  // submit; the image is in PRESENT_SRC (render pass finalLayout), so transition it
  // to TRANSFER_SRC, copy, and back to PRESENT_SRC for presentation.
  fn recordSnapCopy(self: *Vk, cb: c.VkCommandBuffer, dst: Buffer) void {
    var b = c.VkImageMemoryBarrier{
      .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
      .oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
      .image = self.images[self.img_index],
      .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b));
    const region = c.VkBufferImageCopy{
      .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
      .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
      .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
      .imageExtent = .{ .width = self.swap_extent.width, .height = self.swap_extent.height, .depth = 1 },
    };
    vkCmdCopyImageToBuffer(cb, self.images[self.img_index], c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst.buf, 1, @ptrCast(&region));
    b.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    b.dstAccessMask = 0;
    b.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    b.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b));
  }

  // End the render pass, optionally snapshot into `snap`, submit (waiting on
  // image_avail, signalling render_done), and present. Recreates on out-of-date.
  pub fn endFrame(self: *Vk, w: u32, h: u32, snap: ?Buffer) void {
    const cb = self.frame_cmd[self.frame];
    vkCmdEndRenderPass(cb);
    if (snap) |s| self.recordSnapCopy(cb, s);
    _ = vkEndCommandBuffer(cb);

    const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const si = c.VkSubmitInfo{
      .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .waitSemaphoreCount = 1,
      .pWaitSemaphores = &self.img_avail[self.frame],
      .pWaitDstStageMask = &wait_stage,
      .commandBufferCount = 1,
      .pCommandBuffers = &cb,
      .signalSemaphoreCount = 1,
      .pSignalSemaphores = &self.render_done[self.frame],
    };
    _ = vkQueueSubmit(self.queue, 1, @ptrCast(&si), self.in_flight[self.frame]);

    const pi = c.VkPresentInfoKHR{
      .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
      .waitSemaphoreCount = 1,
      .pWaitSemaphores = &self.render_done[self.frame],
      .swapchainCount = 1,
      .pSwapchains = &self.swapchain,
      .pImageIndices = &self.img_index,
    };
    const pr = vkQueuePresentKHR(self.queue, &pi);
    if (pr == c.VK_ERROR_OUT_OF_DATE_KHR or pr == c.VK_SUBOPTIMAL_KHR) self.recreateSwapchain(w, h);
    self.frame = (self.frame + 1) % FRAMES;
  }

  // Plain vertex-attribute description (the FFI layer builds these without needing
  // Vulkan types): location, component count (1..4 → R/RG/RGB/RGBA f32), byte offset.
  pub const VtxAttr = struct { location: u32, comps: u32, offset: u32 };

  // Basic mesh graphics pipeline: vertex+fragment SPIR-V, one vertex binding with
  // caller-derived attributes, depth-test on, alpha blend, dynamic viewport/scissor.
  // (Increment 2: no descriptor sets — uniform/texture/instance variants come next.)
  pub fn createMeshPipeline(self: *Vk, vtx: []const u32, frg: []const u32, in_attrs: []const VtxAttr, stride_bytes: u32, has_uniform_in: bool, n_tex: u32) Error!MeshPipe {
    // A textured mesh always carries the @group(0) uniform block too (matches Dawn).
    const has_uniform = has_uniform_in or n_tex > 0;
    var attr_buf: [16]c.VkVertexInputAttributeDescription = undefined;
    for (in_attrs, 0..) |a, i| {
      attr_buf[i] = .{
        .location = a.location,
        .binding = 0,
        .format = switch (a.comps) {
          1 => c.VK_FORMAT_R32_SFLOAT,
          2 => c.VK_FORMAT_R32G32_SFLOAT,
          3 => c.VK_FORMAT_R32G32B32_SFLOAT,
          else => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        },
        .offset = a.offset,
      };
    }
    const attrs = attr_buf[0..in_attrs.len];
    var mp: MeshPipe = .{ .pipe = undefined, .layout = undefined, .vmod = undefined, .fmod = undefined, .stride = stride_bytes, .has_uniform = has_uniform, .n_tex = n_tex, .tex_dsl = null };
    const vsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = vtx.len * 4, .pCode = vtx.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &vsmi, null, &mp.vmod))) return Error.ShaderModule;
    const fsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = frg.len * 4, .pCode = frg.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &fsmi, null, &mp.fmod))) { vkDestroyShaderModule(self.dev, mp.vmod, null); return Error.ShaderModule; }

    // @group(1) texture layout: n_tex sampled images (0..n-1) + one shared sampler (n).
    if (n_tex > 0) {
      var tb: [MAX_BIND + 1]c.VkDescriptorSetLayoutBinding = undefined;
      var i: u32 = 0;
      while (i < n_tex) : (i += 1) tb[i] = .{ .binding = i, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
      tb[n_tex] = .{ .binding = n_tex, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
      const tdsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = n_tex + 1, .pBindings = &tb };
      _ = vkCreateDescriptorSetLayout(self.dev, &tdsli, null, &mp.tex_dsl);
    }

    var set_layouts: [2]c.VkDescriptorSetLayout = undefined;
    var nset: u32 = 0;
    if (has_uniform) { set_layouts[nset] = self.mesh_dsl; nset += 1; }
    if (n_tex > 0) { set_layouts[nset] = mp.tex_dsl; nset += 1; }
    const plci = c.VkPipelineLayoutCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = nset,
      .pSetLayouts = if (nset > 0) &set_layouts else null,
    };
    if (!ok(vkCreatePipelineLayout(self.dev, &plci, null, &mp.layout))) return Error.Pipeline;

    const stages = [2]c.VkPipelineShaderStageCreateInfo{
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = mp.vmod, .pName = "main" },
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = mp.fmod, .pName = "main" },
    };
    const vbind = c.VkVertexInputBindingDescription{ .binding = 0, .stride = stride_bytes, .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    const vin = c.VkPipelineVertexInputStateCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
      .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vbind,
      .vertexAttributeDescriptionCount = @intCast(attrs.len), .pVertexAttributeDescriptions = attrs.ptr,
    };
    const ia = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    const vps = c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    const rs = c.VkPipelineRasterizationStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = c.VK_POLYGON_MODE_FILL, .cullMode = c.VK_CULL_MODE_NONE, .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0 };
    const ms = c.VkPipelineMultisampleStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
    const ds = c.VkPipelineDepthStencilStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = c.VK_TRUE, .depthWriteEnable = c.VK_TRUE, .depthCompareOp = c.VK_COMPARE_OP_LESS };
    const cba = c.VkPipelineColorBlendAttachmentState{
      .blendEnable = c.VK_TRUE,
      .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .colorBlendOp = c.VK_BLEND_OP_ADD,
      .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = c.VK_BLEND_OP_ADD,
      .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const cb = c.VkPipelineColorBlendStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba };
    const dyn_states = [2]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dyn = c.VkPipelineDynamicStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };

    const gpci = c.VkGraphicsPipelineCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2, .pStages = &stages,
      .pVertexInputState = &vin, .pInputAssemblyState = &ia, .pViewportState = &vps,
      .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = &ds,
      .pColorBlendState = &cb, .pDynamicState = &dyn,
      .layout = mp.layout, .renderPass = self.render_pass, .subpass = 0, .basePipelineIndex = -1,
    };
    if (!ok(vkCreateGraphicsPipelines(self.dev, null, 1, @ptrCast(&gpci), null, @ptrCast(&mp.pipe)))) {
      vkDestroyPipelineLayout(self.dev, mp.layout, null);
      vkDestroyShaderModule(self.dev, mp.vmod, null);
      vkDestroyShaderModule(self.dev, mp.fmod, null);
      return Error.Pipeline;
    }
    return mp;
  }

  pub fn destroyMeshPipeline(self: *Vk, mp: MeshPipe) void {
    vkDestroyPipeline(self.dev, mp.pipe, null);
    vkDestroyPipelineLayout(self.dev, mp.layout, null);
    if (mp.tex_dsl != null) vkDestroyDescriptorSetLayout(self.dev, mp.tex_dsl, null);
    vkDestroyShaderModule(self.dev, mp.vmod, null);
    vkDestroyShaderModule(self.dev, mp.fmod, null);
  }

  // Record a mesh draw into the given (render-pass-open) command buffer, binding
  // the shared vertex buffer at byte_offset so meshes of different strides coexist.
  // `uset` = per-draw uniform set (@group0) or null; `tset` = texture set (@group1)
  // or null. `vbuf`/`byte_offset`/`vcount` describe the vertices (per-frame or retained).
  pub fn drawMesh(_: *Vk, cb: c.VkCommandBuffer, mp: MeshPipe, vbuf: Buffer, byte_offset: u64, vcount: u32, uset: c.VkDescriptorSet, tset: c.VkDescriptorSet) void {
    const off: c.VkDeviceSize = byte_offset;
    vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.pipe);
    if (mp.has_uniform and uset != null)
      vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.layout, 0, 1, @ptrCast(&uset), 0, null);
    if (mp.n_tex > 0 and tset != null)
      vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.layout, 1, 1, @ptrCast(&tset), 0, null);
    vkCmdBindVertexBuffers(cb, 0, 1, @ptrCast(&vbuf.buf), @ptrCast(&off));
    vkCmdDraw(cb, vcount, 1, 0, 0);
  }

  // ── vertex pulling (kk2 §5) ────────────────────────────────────────────────
  // A graphics pipeline with EMPTY vertex-input state: the vertex shader reads
  // `nbuf` storage buffers (set 0, VERTEX stage) indexed by gl_VertexIndex. Same
  // fixed-function state as the mesh pipeline (triangle list, depth test, alpha
  // blend, dynamic viewport) so pulled geometry composites with the rest.
  pub fn createPullPipeline(self: *Vk, vtx: []const u32, frg: []const u32, nbuf: u32) Error!PullPipe {
    var pp: PullPipe = .{ .pipe = undefined, .layout = undefined, .dsl = undefined, .vmod = undefined, .fmod = undefined, .nbuf = nbuf };
    const vsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = vtx.len * 4, .pCode = vtx.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &vsmi, null, &pp.vmod))) return Error.ShaderModule;
    const fsmi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = frg.len * 4, .pCode = frg.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &fsmi, null, &pp.fmod))) { vkDestroyShaderModule(self.dev, pp.vmod, null); return Error.ShaderModule; }

    var binds: [MAX_BIND]c.VkDescriptorSetLayoutBinding = undefined;
    var i: u32 = 0;
    while (i < nbuf) : (i += 1) binds[i] = .{ .binding = i, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT };
    const dsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = nbuf, .pBindings = &binds };
    if (!ok(vkCreateDescriptorSetLayout(self.dev, &dsli, null, &pp.dsl))) { vkDestroyShaderModule(self.dev, pp.vmod, null); vkDestroyShaderModule(self.dev, pp.fmod, null); return Error.Pipeline; }
    const plci = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &pp.dsl };
    if (!ok(vkCreatePipelineLayout(self.dev, &plci, null, &pp.layout))) return Error.Pipeline;

    const stages = [2]c.VkPipelineShaderStageCreateInfo{
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = pp.vmod, .pName = "main" },
      .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = pp.fmod, .pName = "main" },
    };
    const vin = c.VkPipelineVertexInputStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO }; // no bindings/attributes
    const ia = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    const vps = c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    const rs = c.VkPipelineRasterizationStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = c.VK_POLYGON_MODE_FILL, .cullMode = c.VK_CULL_MODE_NONE, .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0 };
    const ms = c.VkPipelineMultisampleStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
    const ds = c.VkPipelineDepthStencilStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = c.VK_TRUE, .depthWriteEnable = c.VK_TRUE, .depthCompareOp = c.VK_COMPARE_OP_LESS };
    const cba = c.VkPipelineColorBlendAttachmentState{
      .blendEnable = c.VK_TRUE,
      .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .colorBlendOp = c.VK_BLEND_OP_ADD,
      .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = c.VK_BLEND_OP_ADD,
      .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const cb = c.VkPipelineColorBlendStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba };
    const dyn_states = [2]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dyn = c.VkPipelineDynamicStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };
    const gpci = c.VkGraphicsPipelineCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2, .pStages = &stages,
      .pVertexInputState = &vin, .pInputAssemblyState = &ia, .pViewportState = &vps,
      .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = &ds,
      .pColorBlendState = &cb, .pDynamicState = &dyn,
      .layout = pp.layout, .renderPass = self.render_pass, .subpass = 0, .basePipelineIndex = -1,
    };
    if (!ok(vkCreateGraphicsPipelines(self.dev, null, 1, @ptrCast(&gpci), null, @ptrCast(&pp.pipe)))) {
      vkDestroyPipelineLayout(self.dev, pp.layout, null);
      vkDestroyDescriptorSetLayout(self.dev, pp.dsl, null);
      vkDestroyShaderModule(self.dev, pp.vmod, null);
      vkDestroyShaderModule(self.dev, pp.fmod, null);
      return Error.Pipeline;
    }
    return pp;
  }

  pub fn destroyPullPipeline(self: *Vk, pp: PullPipe) void {
    vkDestroyPipeline(self.dev, pp.pipe, null);
    vkDestroyPipelineLayout(self.dev, pp.layout, null);
    vkDestroyDescriptorSetLayout(self.dev, pp.dsl, null);
    vkDestroyShaderModule(self.dev, pp.vmod, null);
    vkDestroyShaderModule(self.dev, pp.fmod, null);
  }

  // Allocate a per-frame descriptor set binding `bufs` (storage) in order, and
  // record the pull draw: bind set 0, draw `count` vertices (no vertex buffer).
  pub fn drawPull(self: *Vk, cb: c.VkCommandBuffer, pp: PullPipe, bufs: []const Buffer, count: u32) void {
    var set: c.VkDescriptorSet = undefined;
    const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.pull_upool[self.frame], .descriptorSetCount = 1, .pSetLayouts = &pp.dsl };
    if (!ok(vkAllocateDescriptorSets(self.dev, &dsai, &set))) return;
    var binfo: [MAX_BIND]c.VkDescriptorBufferInfo = undefined;
    var writes: [MAX_BIND]c.VkWriteDescriptorSet = undefined;
    var i: u32 = 0;
    while (i < pp.nbuf) : (i += 1) {
      binfo[i] = .{ .buffer = bufs[i].buf, .offset = 0, .range = c.VK_WHOLE_SIZE };
      writes[i] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = i, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &binfo[i] };
    }
    vkUpdateDescriptorSets(self.dev, pp.nbuf, &writes, 0, null);
    vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipe);
    vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.layout, 0, 1, @ptrCast(&set), 0, null);
    vkCmdDraw(cb, count, 1, 0, 0);
  }

  pub fn createBuffer(self: *Vk, size: u64, uniform: bool) Error!Buffer {
    const sz = if (size < 4) 4 else size;
    const usage: c.VkBufferUsageFlags = if (uniform)
      c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT
    else
      c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    var b: Buffer = .{ .buf = undefined, .mem = undefined, .size = sz, .mapped = undefined, .uniform = uniform };
    const bi = c.VkBufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sz, .usage = usage, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
    if (!ok(vkCreateBuffer(self.dev, &bi, null, &b.buf))) return Error.OutOfMemory;
    var req: c.VkMemoryRequirements = undefined;
    vkGetBufferMemoryRequirements(self.dev, b.buf, &req);
    const ai = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = self.memtype };
    if (!ok(vkAllocateMemory(self.dev, &ai, null, &b.mem))) { vkDestroyBuffer(self.dev, b.buf, null); return Error.OutOfMemory; }
    _ = vkBindBufferMemory(self.dev, b.buf, b.mem, 0);
    var p: ?*anyopaque = null;
    _ = vkMapMemory(self.dev, b.mem, 0, req.size, 0, &p);
    b.mapped = @ptrCast(p.?);
    return b;
  }

  pub fn destroyBuffer(self: *Vk, b: Buffer) void {
    vkDestroyBuffer(self.dev, b.buf, null);
    vkFreeMemory(self.dev, b.mem, null);
  }

  // Host-visible vertex buffer (persistently mapped), for per-frame mesh uploads.
  pub fn createVertexBuffer(self: *Vk, size: u64) Error!Buffer {
    const sz = if (size < 4) 4 else size;
    var b: Buffer = .{ .buf = undefined, .mem = undefined, .size = sz, .mapped = undefined, .uniform = false };
    const bi = c.VkBufferCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sz, .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
    if (!ok(vkCreateBuffer(self.dev, &bi, null, &b.buf))) return Error.OutOfMemory;
    var req: c.VkMemoryRequirements = undefined;
    vkGetBufferMemoryRequirements(self.dev, b.buf, &req);
    const ai = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = self.memtype };
    if (!ok(vkAllocateMemory(self.dev, &ai, null, &b.mem))) { vkDestroyBuffer(self.dev, b.buf, null); return Error.OutOfMemory; }
    _ = vkBindBufferMemory(self.dev, b.buf, b.mem, 0);
    var p: ?*anyopaque = null;
    _ = vkMapMemory(self.dev, b.mem, 0, req.size, 0, &p);
    b.mapped = @ptrCast(p.?);
    return b;
  }

  // Persistent coherent mapping ⇒ upload/readback are plain memcpy.
  pub fn write(_: *Vk, b: Buffer, bytes: []const u8) void {
    const n = @min(bytes.len, b.size);
    @memcpy(b.mapped[0..n], bytes[0..n]);
  }
  pub fn read(_: *Vk, b: Buffer) []const u8 {
    return b.mapped[0..b.size]; // valid after a preceding waitIdle
  }

  // Upload RGBA8 pixel data to a sampled texture (staging buffer + copy + layout
  // transitions via a one-time submit), returning image+view+sampler.
  pub fn createTexture(self: *Vk, w: u32, h: u32, rgba: []const u8) Error!Texture {
    var t: Texture = undefined;
    const ici = c.VkImageCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = c.VK_IMAGE_TYPE_2D, .format = c.VK_FORMAT_R8G8B8A8_UNORM,
      .extent = .{ .width = w, .height = h, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = c.VK_SAMPLE_COUNT_1_BIT,
      .tiling = c.VK_IMAGE_TILING_OPTIMAL, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (!ok(vkCreateImage(self.dev, &ici, null, &t.img))) return Error.OutOfMemory;
    var req: c.VkMemoryRequirements = undefined;
    vkGetImageMemoryRequirements(self.dev, t.img, &req);
    const ai = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = self.memtype };
    if (!ok(vkAllocateMemory(self.dev, &ai, null, &t.mem))) { vkDestroyImage(self.dev, t.img, null); return Error.OutOfMemory; }
    _ = vkBindImageMemory(self.dev, t.img, t.mem, 0);

    // staging buffer with the pixel data
    const stage = try self.createBuffer(@as(u64, w) * h * 4, false);
    defer self.destroyBuffer(stage);
    @memcpy(stage.mapped[0 .. rgba.len], rgba);

    // one-time: UNDEFINED→TRANSFER_DST, copy, →SHADER_READ_ONLY
    var tcb: c.VkCommandBuffer = undefined;
    const cbai = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = self.cmd_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    _ = vkAllocateCommandBuffers(self.dev, &cbai, &tcb);
    const bi = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    _ = vkBeginCommandBuffer(tcb, &bi);
    var b = c.VkImageMemoryBarrier{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .image = t.img, .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
    vkCmdPipelineBarrier(tcb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b));
    const region = c.VkBufferImageCopy{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = w, .height = h, .depth = 1 } };
    vkCmdCopyBufferToImage(tcb, stage.buf, t.img, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));
    b.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    b.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    b.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(tcb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b));
    _ = vkEndCommandBuffer(tcb);
    const si = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&tcb) };
    _ = vkQueueSubmit(self.queue, 1, @ptrCast(&si), null);
    _ = vkQueueWaitIdle(self.queue);
    _ = vkResetCommandPool(self.dev, self.cmd_pool, 0);

    const ivci = c.VkImageViewCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = t.img, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .components = .{}, .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
    _ = vkCreateImageView(self.dev, &ivci, null, &t.view);
    const smci = c.VkSamplerCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = c.VK_FILTER_LINEAR, .minFilter = c.VK_FILTER_LINEAR, .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT, .maxLod = 1.0 };
    _ = vkCreateSampler(self.dev, &smci, null, &t.sampler);
    return t;
  }

  pub fn destroyTexture(self: *Vk, t: Texture) void {
    vkDestroySampler(self.dev, t.sampler, null);
    vkDestroyImageView(self.dev, t.view, null);
    vkDestroyImage(self.dev, t.img, null);
    vkFreeMemory(self.dev, t.mem, null);
  }

  pub fn createComputePipeline(self: *Vk, spirv: []const u32, nbind: u32, uni_idx: i32, wgx: u32) Error!Pipeline {
    var p: Pipeline = .{ .pipe = undefined, .layout = undefined, .dsl = undefined, .module = undefined, .nbind = nbind, .uni_idx = uni_idx, .wgx = if (wgx == 0) 64 else wgx };

    const smi = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = spirv.len * 4, .pCode = spirv.ptr };
    if (!ok(vkCreateShaderModule(self.dev, &smi, null, &p.module))) return Error.ShaderModule;

    var binds: [MAX_BIND]c.VkDescriptorSetLayoutBinding = undefined;
    var i: u32 = 0;
    while (i < nbind) : (i += 1) {
      const is_uni = (uni_idx >= 0 and @as(i32, @intCast(i)) == uni_idx);
      binds[i] = .{
        .binding = i,
        .descriptorType = if (is_uni) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
      };
    }
    const dsli = c.VkDescriptorSetLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = nbind, .pBindings = &binds };
    if (!ok(vkCreateDescriptorSetLayout(self.dev, &dsli, null, &p.dsl))) { vkDestroyShaderModule(self.dev, p.module, null); return Error.Pipeline; }

    const pli = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &p.dsl };
    if (!ok(vkCreatePipelineLayout(self.dev, &pli, null, &p.layout))) { vkDestroyDescriptorSetLayout(self.dev, p.dsl, null); vkDestroyShaderModule(self.dev, p.module, null); return Error.Pipeline; }

    const cpi = c.VkComputePipelineCreateInfo{
      .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = p.module, .pName = "main" },
      .layout = p.layout,
      .basePipelineIndex = -1,
    };
    if (!ok(vkCreateComputePipelines(self.dev, null, 1, @ptrCast(&cpi), null, @ptrCast(&p.pipe)))) {
      vkDestroyPipelineLayout(self.dev, p.layout, null);
      vkDestroyDescriptorSetLayout(self.dev, p.dsl, null);
      vkDestroyShaderModule(self.dev, p.module, null);
      return Error.Pipeline;
    }
    return p;
  }

  pub fn destroyPipeline(self: *Vk, p: Pipeline) void {
    vkDestroyPipeline(self.dev, p.pipe, null);
    vkDestroyPipelineLayout(self.dev, p.layout, null);
    vkDestroyDescriptorSetLayout(self.dev, p.dsl, null);
    vkDestroyShaderModule(self.dev, p.module, null);
  }

  // Allocate + write one descriptor set binding `bufs` in order (types from the pipeline).
  fn allocSet(self: *Vk, p: Pipeline, bufs: []const Buffer) c.VkDescriptorSet {
    var set: c.VkDescriptorSet = undefined;
    const dsai = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.desc_pool, .descriptorSetCount = 1, .pSetLayouts = &p.dsl };
    _ = vkAllocateDescriptorSets(self.dev, &dsai, &set);
    var binfo: [MAX_BIND]c.VkDescriptorBufferInfo = undefined;
    var writes: [MAX_BIND]c.VkWriteDescriptorSet = undefined;
    for (bufs, 0..) |b, i| {
      const is_uni = (p.uni_idx >= 0 and @as(i32, @intCast(i)) == p.uni_idx);
      binfo[i] = .{ .buffer = b.buf, .offset = 0, .range = b.size };
      writes[i] = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstBinding = @intCast(i),
        .descriptorCount = 1,
        .descriptorType = if (is_uni) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &binfo[i],
      };
    }
    vkUpdateDescriptorSets(self.dev, @intCast(bufs.len), &writes, 0, null);
    return set;
  }

  fn groups(n: u32, wgx: u32) u32 {
    const w = if (wgx == 0) 64 else wgx;
    return (n + w - 1) / w;
  }

  // Ensure a command buffer is open for recording; flush first if the descriptor
  // budget for this batch would be exceeded by `need` more sets.
  fn ensureRecording(self: *Vk, need: u32) void {
    if (self.recording and self.nsets + need > POOL_SETS) self.sync();
    if (!self.recording) {
      const cbai = c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = self.cmd_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
      _ = vkAllocateCommandBuffers(self.dev, &cbai, &self.cur);
      const bi = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      _ = vkBeginCommandBuffer(self.cur, &bi);
      self.recording = true;
      self.nsets = 0;
    }
  }

  // Submit the recorded batch and block until done; then reset the transient
  // pools. Host must call this before reading any buffer's mapped memory (coherent
  // memory + a completed queue ⇒ GPU writes visible). No-op if nothing recorded.
  pub fn sync(self: *Vk) void {
    if (!self.recording) return;
    _ = vkEndCommandBuffer(self.cur);
    const si = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&self.cur) };
    _ = vkQueueSubmit(self.queue, 1, @ptrCast(&si), null);
    _ = vkQueueWaitIdle(self.queue);
    _ = vkResetCommandPool(self.dev, self.cmd_pool, 0);
    _ = vkResetDescriptorPool(self.dev, self.desc_pool, 0);
    self.recording = false;
    self.nsets = 0;
  }

  // compute→compute barrier so a prior dispatch's storage writes feed this one.
  // (Metal auto-tracks within a command buffer; explicit + portable regardless.)
  fn computeBarrier(cb: c.VkCommandBuffer) void {
    const b = c.VkMemoryBarrier{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT };
    vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, @ptrCast(&b), 0, null, 0, null);
  }

  // Record one dispatch of `nthreads` elements into the running batch (deferred;
  // call sync() before reading results). Ordered after any prior recorded dispatch.
  pub fn dispatch(self: *Vk, p: Pipeline, bufs: []const Buffer, nthreads: u32) void {
    self.ensureRecording(1);
    const set = self.allocSet(p, bufs);
    computeBarrier(self.cur);
    vkCmdBindPipeline(self.cur, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.pipe);
    vkCmdBindDescriptorSets(self.cur, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, @ptrCast(&set), 0, null);
    vkCmdDispatch(self.cur, groups(nthreads, p.wgx), 1, 1);
    self.nsets += 1;
  }

  // Record `reps` passes alternating bind sets A (even) / B (odd), a barrier
  // between each so pass k's writes feed k+1. Deferred like dispatch.
  pub fn dispatchLoop(self: *Vk, p: Pipeline, bufsA: []const Buffer, bufsB: []const Buffer, nthreads: u32, reps: u32) void {
    self.ensureRecording(2);
    const setA = self.allocSet(p, bufsA);
    const setB = self.allocSet(p, bufsB);
    const g = groups(nthreads, p.wgx);
    vkCmdBindPipeline(self.cur, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.pipe);
    var k: u32 = 0;
    while (k < reps) : (k += 1) {
      computeBarrier(self.cur);
      const set = if (k % 2 == 0) setA else setB;
      vkCmdBindDescriptorSets(self.cur, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, @ptrCast(&set), 0, null);
      vkCmdDispatch(self.cur, g, 1, 1);
    }
    self.nsets += 2;
  }
};

// Parse the LocalSize x operand from OpExecutionMode (opcode 16, mode 17),
// defaulting to 64. Mirrors localSizeX in gpu.zig so dispatch matches dye's `wg`.
pub fn localSizeX(words: []const u32) u32 {
  if (words.len < 6) return 64;
  var i: usize = 5;
  while (i < words.len) {
    const wc: usize = words[i] >> 16;
    const op: u16 = @truncate(words[i] & 0xFFFF);
    if (wc == 0) break;
    if (op == 16 and i + 3 < words.len and words[i + 2] == 17) {
      const x = words[i + 3];
      return if (x == 0) 64 else x;
    }
    i += wc;
  }
  return 64;
}
