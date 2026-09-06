--!strict
--- Small table helpers used across config merging and profile handling.

local TableUtil = {}

function TableUtil.DeepCopy<T>(source: T & any): T
	if type(source) ~= "table" then
		return source
	end
	local copy = {}
	for key, value in source do
		copy[key] = TableUtil.DeepCopy(value)
	end
	return (copy :: any) :: T
end

--- Fills in keys missing from `target` using `template`. Used for save-data migration:
--- a profile saved before a feature existed simply gains the new defaults.
function TableUtil.Reconcile(target: { [any]: any }, template: { [any]: any })
	for key, value in template do
		if target[key] == nil then
			target[key] = TableUtil.DeepCopy(value)
		elseif type(value) == "table" and type(target[key]) == "table" then
			TableUtil.Reconcile(target[key], value)
		end
	end
	return target
end

function TableUtil.Count(source: { [any]: any }): number
	local count = 0
	for _ in source do
		count += 1
	end
	return count
end

function TableUtil.Keys<K>(source: { [K]: any }): { K }
	local keys = {}
	for key in source do
		table.insert(keys, key)
	end
	return keys
end

function TableUtil.Values<V>(source: { [any]: V }): { V }
	local values = {}
	for _, value in source do
		table.insert(values, value)
	end
	return values
end

function TableUtil.Filter<T>(source: { T }, predicate: (T, number) -> boolean): { T }
	local result = {}
	for index, value in source do
		if predicate(value, index) then
			table.insert(result, value)
		end
	end
	return result
end

function TableUtil.Map<T, R>(source: { T }, transform: (T, number) -> R): { R }
	local result = table.create(#source)
	for index, value in source do
		result[index] = transform(value, index)
	end
	return result
end

function TableUtil.Find<T>(source: { T }, predicate: (T) -> boolean): (T?, number?)
	for index, value in source do
		if predicate(value) then
			return value, index
		end
	end
	return nil, nil
end

function TableUtil.Contains(source: { any }, needle: any): boolean
	return table.find(source, needle) ~= nil
end

--- Sums a numeric field across a dictionary of records.
function TableUtil.SumBy(source: { [any]: any }, field: string): number
	local total = 0
	for _, record in source do
		total += (record[field] or 0)
	end
	return total
end

return TableUtil
