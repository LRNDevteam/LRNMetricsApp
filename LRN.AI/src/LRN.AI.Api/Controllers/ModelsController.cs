using LRN.AI.Api.Contracts.Models;
using LRN.AI.Api.Security;
using LRN.AI.Application.Common;
using LRN.AI.Application.ModelComparison;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace LRN.AI.Api.Controllers;

/// <summary>
/// Phase 1 model evaluation: installed models and side-by-side comparison. Restricted to the configured
/// evaluation roles because the compare endpoint accepts free text.
/// </summary>
[ApiController]
[Route("api/ai/v1/models")]
[Authorize(Policy = AuthPolicies.ModelEvaluation)]
[Produces("application/json")]
public sealed class ModelsController(IModelEvaluationService evaluationService) : ControllerBase
{
    /// <summary>Models installed in the local Ollama instance. 503 when Ollama cannot be reached.</summary>
    [HttpGet]
    [ProducesResponseType<ModelsResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status503ServiceUnavailable)]
    public async Task<ActionResult<ModelsResponse>> List(CancellationToken cancellationToken)
    {
        try
        {
            var catalog = await evaluationService.ListModelsAsync(Caller(), cancellationToken);
            return Ok(ModelsResponse.From(catalog));
        }
        catch (LLMProviderException ex)
        {
            return ProviderUnavailable(ex);
        }
    }

    /// <summary>
    /// Sends the same de-identified prompt and settings to 1-3 installed models. 200 with per-model success/failure,
    /// 400 for invalid input, 503 when Ollama cannot be reached at all.
    /// </summary>
    [HttpPost("compare")]
    [EnableRateLimiting(RateLimitPolicies.Compare)]
    [ProducesResponseType<CompareModelsResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ValidationProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status503ServiceUnavailable)]
    public async Task<ActionResult<CompareModelsResponse>> Compare([FromBody] CompareModelsRequest request, CancellationToken cancellationToken)
    {
        try
        {
            var result = await evaluationService.CompareAsync(request.ToApplication(), Caller(), cancellationToken);
            return Ok(CompareModelsResponse.From(result));
        }
        catch (RequestValidationException ex)
        {
            foreach (var (field, messages) in ex.Errors)
                foreach (var message in messages)
                    ModelState.AddModelError(field, message);
            return ValidationProblem(ModelState);
        }
        catch (LLMProviderException ex)
        {
            return ProviderUnavailable(ex);
        }
    }

    private ObjectResult ProviderUnavailable(LLMProviderException ex)
    {
        var problem = ProblemDetailsFactory.CreateProblemDetails(
            HttpContext,
            statusCode: StatusCodes.Status503ServiceUnavailable,
            title: "The model provider is unavailable.",
            detail: ex.Code.ToCallerMessage());
        problem.Extensions["connected"] = false;
        problem.Extensions["code"] = ex.Code.ToString();
        return new ObjectResult(problem) { StatusCode = StatusCodes.Status503ServiceUnavailable };
    }

    private CallerContext Caller() => new(CallerIdentity.UserId(User), HttpContext.TraceIdentifier);
}
