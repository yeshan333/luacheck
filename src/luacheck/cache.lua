local utils = require "luacheck.utils"

local cache = {}

-- Cache file contains check results for n unique filenames.
-- Cache file consists of 3n lines, 3 lines per file.
-- For each file, first line is the filename, second is modification time, third is check result in lua table format.
-- String fields are compressed into array indexes.

local fields = {
   "code",
   "name",
   "line",
   "column",
   "prev_line",
   "prev_column",
   "secondary",
   "func",
   "vararg",
   "filtered",
   "invalid",
   "unpaired",
   "read_only",
   "global",
   "filtered_111",
   "filtered_121",
   "filtered_131",
   "filtered_112",
   "filtered_122",
   "filtered_113",
   "definition",
   "in_module"
}

-- Converts table with fields into table with indexes.
local function compress(t)
   local res = {}

   for index, field in ipairs(fields) do
      res[index] = t[field]
   end

   return res
end

-- Serializes event into a string.
local function serialize_event(event)
   event = compress(event)
   local buffer = {"{"}
   local is_sparse

   for i = 1, #fields do
      local value = event[i]

      if not value then
         is_sparse = true
      else
         if is_sparse then
            table.insert(buffer, ("[%d]="):format(i))
         end

         if type(value) == "string" then
            table.insert(buffer, ("%q"):format(value))
         else
            table.insert(buffer, tostring(value))
         end

         table.insert(buffer, ",")
      end
   end

   table.insert(buffer, "}")
   return table.concat(buffer)
end

-- Serializes check result into a string.
function cache.serialize(events)
   if not events then
      return "return false"
   end

   local buffer = {"return {"}

   for _, event in ipairs(events) do
      table.insert(buffer, serialize_event(event))
      table.insert(buffer, ",")
   end

   table.insert(buffer, "}")
   return table.concat(buffer)
end

-- Returns array of triplets of lines from cache fh.
local function read_triplets(fh)
   local res = {}

   while true do
      local filename = fh:read()

      if filename then
         local mtime = fh:read() or ""
         local cached = fh:read() or ""
         table.insert(res, {filename, mtime, cached})
      else
         break
      end
   end

   return res
end

-- Writes cache triplets into fh.
local function write_triplets(fh, triplets)
   for _, triplet in ipairs(triplets) do
      fh:write(triplet[1], "\n")
      fh:write(triplet[2], "\n")
      fh:write(triplet[3], "\n")
   end
end

-- Converts table with indexes into table with fields.
local function decompress(t)
   local res = {}

   for index, field in ipairs(fields) do
      res[field] = t[index]
   end

   return res
end

-- Loads cached results from string, returns results or nil.
local function load_cached(cached)
   local func = utils.load(cached, {})

   if not func then
      return
   end

   local ok, res = pcall(func)

   if not ok or type(res) ~= "table" then
      return
   end

   local decompressed = {}

   for i, event in ipairs(res) do
      if type(event) ~= "table" then
         return
      end

      decompressed[i] = decompress(event)
   end

   return decompressed
end

-- Loads cache for filenames given mtimes from cache cache_filename.
-- Returns table mapping filenames to cached check results.
-- On corrupted cache returns nil.
function cache.load(cache_filename, filenames, mtimes)
   local fh = io.open(cache_filename, "rb")

   if not fh then
      return {}
   end

   local result = {}
   local not_yet_found = utils.array_to_set(filenames)

   while next(not_yet_found) do
      local filename = fh:read()

      if not filename then
         fh:close()
         return result
      end

      local mtime = fh:read()
      local cached = fh:read()

      if not mtime or not cached then
         fh:close()
         return
      end

      mtime = tonumber(mtime)

      if not mtime then
         fh:close()
         return
      end

      if not_yet_found[filename] then
         if mtimes[not_yet_found[filename]] == mtime then
            result[filename] = load_cached(cached)

            if not result[filename] then
               fh:close()
               return
            end
         end

         not_yet_found[filename] = nil
      end
   end

   fh:close()
   return result
end

-- Updates cache at cache_filename with results for filenames.
-- Returns success flag + wether update was append-only.
function cache.update(cache_filename, filenames, mtimes, results)
   local old_triplets
   local fh = io.open(cache_filename, "rb")

   if not fh then
      old_triplets = {}
   else
      old_triplets = read_triplets(fh)
      fh:close()
   end

   local can_append = true
   local filename_set = utils.array_to_set(filenames)
   local old_filename_set = {}

   -- Update old cache for files which got a new result.
   for i, triplet in ipairs(old_triplets) do
      old_filename_set[triplet[1]] = true
      local file_index = filename_set[triplet[1]]

      if file_index then
         can_append = false
         old_triplets[i][2] = mtimes[file_index]
         old_triplets[i][3] = cache.serialize(results[file_index])
      end
   end

   local new_triplets = {}

   for _, filename in ipairs(filenames) do
      -- Use unique index (there could be duplicate filenames).
      local file_index = filename_set[filename]

      if file_index and not old_filename_set[filename] then
         table.insert(new_triplets, {
            filename,
            mtimes[file_index],
            cache.serialize(results[file_index])
         })
         -- Do not save result for this filename again.
         filename_set[filename] = nil
      end
   end

   if can_append then
      if #new_triplets > 0 then
         fh = io.open(cache_filename, "ab")

         if not fh then
            return false
         end

         write_triplets(fh, new_triplets)
         fh:close()
      end
   else
      fh = io.open(cache_filename, "wb")

      if not fh then
         return false
      end

      write_triplets(fh, old_triplets)
      write_triplets(fh, new_triplets)
      fh:close()
   end

   return true, can_append
end

return cache