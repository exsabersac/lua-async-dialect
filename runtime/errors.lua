--[[
  共享错误形状。取消用表标记，与普通 reject 的任意 reason 区分。
]]

local errors = {}

--- 构造取消错误（OperationCanceled 风格）
-- @param token_or_reason CancellationToken | table | string | nil
function errors.canceled(token_or_reason)
  if type(token_or_reason) == "table" and token_or_reason.canceled == true then
    return token_or_reason
  end
  local token = nil
  local reason = nil
  if type(token_or_reason) == "table" and token_or_reason.is_cancellation_requested then
    token = token_or_reason
  else
    reason = token_or_reason
  end
  return {
    canceled = true,
    token = token,
    reason = reason,
    message = "OperationCanceled",
  }
end

function errors.is_canceled(e)
  return type(e) == "table" and e.canceled == true
end

return errors
