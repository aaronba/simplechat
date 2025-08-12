#!/usr/bin/env python3
"""
Simple Azure AI Search Test
Tests Azure AI Search with optional OpenAI for full hybrid search.
Includes comprehensive diagnostic capabilities and verbose logging.

Environment Variables:
- AZURE_AI_SEARCH_ENDPOINT: Your Azure AI Search service endpoint
- AZURE_AI_SEARCH_KEY: Your Azure AI Search admin key
- AZURE_OPENAI_ENDPOINT: Your Azure OpenAI service endpoint (optional)
- AZURE_OPENAI_KEY: Your Azure OpenAI service key (optional)
- AZURE_OPENAI_COMPLETION_DEPLOYMENT: GPT completion model deployment name (default: gpt-4.1)
- AZURE_OPENAI_EMBEDDING_DEPLOYMENT: Embedding model deployment name (default: text-embedding-ada-002)
- TEST_QUERY: Custom test query (default: "what did Ahmed have for lunch")

Set environment variables or edit the script directly.
"""

import os
import sys
import json
import traceback
import logging
from datetime import datetime
from typing import List, Dict, Any, Optional

# Add required Azure packages
try:
    from azure.core.credentials import AzureKeyCredential
    from azure.core.exceptions import HttpResponseError
    from azure.search.documents import SearchClient
    from azure.search.documents.models import VectorizedQuery
except ImportError as e:
    print(f"❌ Missing Azure packages: {e}")
    print("Install with: pip install azure-search-documents azure-core")
    sys.exit(1)

# Set up logging for verbose error analysis
# Control log level via LOG_LEVEL environment variable (DEBUG, INFO, WARNING, ERROR)
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
log_level_mapping = {
    'DEBUG': logging.DEBUG,
    'INFO': logging.INFO,
    'WARNING': logging.WARNING,
    'ERROR': logging.ERROR
}

logging.basicConfig(
    level=log_level_mapping.get(log_level, logging.INFO),
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)

# Control Azure SDK HTTP logging separately
azure_log_level = logging.WARNING if log_level != 'DEBUG' else logging.DEBUG
azure_loggers = [
    'azure.core.pipeline.policies.http_logging_policy',
    'azure.search.documents._search_client',
    'azure.core.pipeline.policies',
    'azure',
    'urllib3.connectionpool'
]

for logger_name in azure_loggers:
    azure_logger = logging.getLogger(logger_name)
    azure_logger.setLevel(azure_log_level)

logger = logging.getLogger(__name__)

def log_http_error_details(error: Exception, search_type: str, query: str):
    """Log detailed information about HTTP errors."""
    
    logger.error(f"🚨 HTTP Error in {search_type} search:")
    logger.error(f"   Query: '{query}'")
    logger.error(f"   Error Type: {type(error).__name__}")
    logger.error(f"   Error Message: {str(error)}")
    
    if hasattr(error, 'status_code'):
        logger.error(f"   HTTP Status Code: {error.status_code}")
    
    if hasattr(error, 'error'):
        logger.error(f"   Azure Error Details: {error.error}")
    
    if hasattr(error, 'message'):
        logger.error(f"   Detailed Message: {error.message}")
    
    # Log full traceback for debugging
    logger.debug("   Full Traceback:")
    logger.debug(traceback.format_exc())


# Try to import OpenAI for hybrid search

# Try to import OpenAI (optional)
try:
    import openai
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False


class SimpleSearchTest:
    """Simple test class for Azure AI Search with optional hybrid functionality."""
    
    def __init__(self, search_endpoint: str, search_key: str, openai_endpoint: str = None, openai_key: str = None):
        """
        Initialize with Azure AI Search credentials and optional OpenAI.
        
        Args:
            search_endpoint: Azure AI Search endpoint
            search_key: Azure AI Search admin key
            openai_endpoint: Azure OpenAI endpoint (optional)
            openai_key: Azure OpenAI key (optional)
        """
        # Safe endpoint handling - ensure we have strings before operations
        self.search_endpoint = (search_endpoint or "").rstrip('/')
        self.search_key = search_key or ""
        self.has_openai = (HAS_OPENAI and openai_endpoint and openai_key and 
                          "your-openai" not in str(openai_endpoint or ""))
        
        # Initialize search clients
        self.user_search_client = SearchClient(
            endpoint=self.search_endpoint,
            index_name="simplechat-user-index",
            credential=AzureKeyCredential(self.search_key)
        )
        
        self.group_search_client = SearchClient(
            endpoint=self.search_endpoint,
            index_name="simplechat-group-index", 
            credential=AzureKeyCredential(self.search_key)
        )
        
        # Initialize OpenAI client if available
        if self.has_openai:
            self.openai_client = openai.AzureOpenAI(
                azure_endpoint=openai_endpoint,
                api_key=openai_key,
                api_version="2024-02-01"
            )
            print("✓ OpenAI client initialized - full hybrid search available")
        else:
            self.openai_client = None
            print("ℹ️  No OpenAI - text search only")
        
        # Track search results for summary
        self.search_summary = {
            'query': '',
            'best_results': [],
            'semantic_answers': [],
            'enhanced_answer': '',
            'highest_scoring_source': ''
        }
    
    def generate_enhanced_answer(self, query: str, search_results: List[Dict], semantic_answers: List[str]) -> Optional[str]:
        """Generate an enhanced answer using GPT-4 based on search results and semantic answers."""
        if not self.has_openai:
            return None
            
        try:
            # Prepare context from search results
            context_chunks = []
            for i, result in enumerate(search_results[:3]):  # Use top 3 results
                chunk_text = result.get('chunk_text', '')
                file_name = result.get('file_name', 'Unknown')
                if chunk_text:
                    context_chunks.append(f"Document {i+1} ({file_name}):\n{chunk_text[:500]}...")
            
            # Combine semantic answers
            semantic_context = "\n".join([f"Semantic Answer {i+1}: {answer}" for i, answer in enumerate(semantic_answers)])
            
            # Create the prompt
            context_text = "\n\n".join(context_chunks)
            prompt = f"""Based on the following search results and semantic answers, provide a clear, concise answer to the user's question.

User Question: {query}

Semantic Answers from Azure AI Search:
{semantic_context}

Additional Context from Documents:
{context_text}

Please provide a direct, helpful answer based on this information. If the information is insufficient, say so."""

            # Use GPT-4.1 for completion (check for custom deployment name)
            completion_model = os.getenv("AZURE_OPENAI_COMPLETION_DEPLOYMENT", "gpt-4.1")
            response = self.openai_client.chat.completions.create(
                model=completion_model,
                messages=[
                    {"role": "system", "content": "You are a helpful assistant that answers questions based on provided context."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=300,
                temperature=0.3
            )
            
            return response.choices[0].message.content
            
        except Exception as e:
            logger.error(f"GPT-4 completion failed: {e}")
            return None
    
    def _update_search_summary(self, query: str, search_results: List[Dict], semantic_answers: List[str], enhanced_answer: str, index_type: str):
        """Update the search summary with the best results and answers."""
        if not search_results:
            return
            
        # Update the query
        self.search_summary['query'] = query
        
        # Get the highest-scoring result from this search
        best_result = search_results[0] if search_results else None
        if best_result:
            file_name = best_result.get('file_name', 'Unknown')
            # Look for score in the right field - our search_results use 'score' not '@search.score'
            score = best_result.get('score', best_result.get('@search.score', 0))
            
            # Handle numeric score formatting safely
            if isinstance(score, (int, float)):
                score_str = f"{score:.3f}"
            else:
                score_str = str(score)
            
            # Only update the highest scoring source if this score is better
            current_best_score = 0
            if self.search_summary.get('highest_scoring_source'):
                # Extract current best score from the existing string
                import re
                match = re.search(r'Score: ([\d.]+)', self.search_summary['highest_scoring_source'])
                if match:
                    current_best_score = float(match.group(1))
            
            # Update if this is the new highest score
            if isinstance(score, (int, float)) and score > current_best_score:
                self.search_summary['highest_scoring_source'] = f"{file_name} (Score: {score_str}, {index_type} index)"
                logger.debug(f"New highest scoring result: {file_name} with score {score:.3f} from {index_type} index")
                
                # Update best results only if this is truly the new best
                self.search_summary['best_results'] = []
                for i, result in enumerate(search_results[:3]):
                    # Look for score in the right field
                    result_score = result.get('score', result.get('@search.score', 'N/A'))
                    result_info = {
                        'file_name': result.get('file_name', 'Unknown'),
                        'score': result_score,
                        'index': index_type
                    }
                    self.search_summary['best_results'].append(result_info)
                    logger.debug(f"Updated best result {i+1}: {result_info['file_name']} with score {result_score}")
        
        # Update semantic answers and enhanced answer (always update these)
        if semantic_answers:
            self.search_summary['semantic_answers'] = semantic_answers
        if enhanced_answer:
            self.search_summary['enhanced_answer'] = enhanced_answer
    
    def generate_embedding(self, text: str) -> Optional[List[float]]:
        """Generate embedding for the given text (if OpenAI is available)."""
        if not self.has_openai:
            return None
            
        try:
            embedding_model = os.getenv("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-ada-002")
            response = self.openai_client.embeddings.create(
                input=text,
                model=embedding_model
            )
            return response.data[0].embedding
        except Exception as e:
            print(f"❌ Embedding generation failed: {e}")
            return None
    
    def test_basic_search(self, query: str, index_type: str = "user") -> bool:
        """Test basic text search with detailed error logging."""
        print(f"\n🔍 Testing basic text search: '{query}' on {index_type} index")
        
        try:
            client = self.user_search_client if index_type == "user" else self.group_search_client
            
            logger.debug(f"Starting basic search: query='{query}', index='{index_type}'")
            
            results = client.search(
                search_text=query,
                top=5
            )
            
            result_count = 0
            for result in results:
                result_count += 1
                if result_count <= 3:  # Show first 3 results
                    # Safe formatting for score - handle potential 'N/A' or None values
                    score = result.get('@search.score', 'N/A')
                    if isinstance(score, (int, float)):
                        score_str = f"{score:.3f}"
                    else:
                        score_str = str(score)
                    print(f"   • {result.get('file_name', 'Unknown')} (Score: {score_str})")
            
            print(f"   ✓ Basic text search works - {result_count} total results")
            logger.debug(f"Basic search completed successfully: {result_count} results")
            return True
            
        except HttpResponseError as e:
            log_http_error_details(e, "basic text", query)
            print(f"   ❌ Basic text search failed: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error in basic search: {e}")
            logger.debug(traceback.format_exc())
            print(f"   ❌ Basic text search failed: {e}")
            return False
    
    def test_semantic_search(self, query: str, index_type: str = "user") -> bool:
        """Test semantic search."""
        print(f"\n🔍 Testing semantic search: '{query}' on {index_type} index")
        
        try:
            client = self.user_search_client if index_type == "user" else self.group_search_client
            semantic_config = "nexus-user-index-semantic-configuration" if index_type == "user" else "nexus-group-index-semantic-configuration"
            
            results = client.search(
                search_text=query,
                query_type="semantic",
                semantic_configuration_name=semantic_config,
                query_caption="extractive",
                query_answer="extractive",
                top=5
            )
            
            result_count = 0
            answers_found = []
            search_results = []
            
            # Extract semantic answers if available
            if hasattr(results, 'get_answers') and callable(results.get_answers):
                try:
                    semantic_answers = results.get_answers()
                    if semantic_answers:
                        print(f"   📝 SEMANTIC ANSWERS FOUND:")
                        for i, answer in enumerate(semantic_answers):
                            answer_text = answer.text if hasattr(answer, 'text') else str(answer)
                            print(f"   {i+1}. {answer_text}")
                            logger.info(f"Semantic Answer {i+1}: {answer_text}")
                            answers_found.append(answer_text)
                except Exception as e:
                    logger.debug(f"Could not extract answers: {e}")
            
            for result in results:
                # Store the raw result with Azure's score format for GPT enhancement
                actual_score = result.get('@search.score', 0)
                logger.debug(f"Raw search result: file='{result.get('file_name', 'Unknown')}', score={actual_score} (type: {type(actual_score)})")
                
                search_results.append({
                    'file_name': result.get('file_name', 'Unknown'),
                    'chunk_text': result.get('chunk_text', ''),
                    'score': actual_score,  # Extract the actual search score
                    '@search.score': actual_score  # Keep both formats for compatibility
                })
                result_count += 1
                if result_count <= 3:  # Show first 3 results
                    print(f"   • {result.get('file_name', 'Unknown')} (Score: {actual_score:.3f})")
                    
                    # Check for captions in the result
                    if '@search.captions' in result:
                        captions = result['@search.captions']
                        if captions:
                            caption_text = captions[0].text if hasattr(captions[0], 'text') else str(captions[0])
                            print(f"     Caption: {caption_text}")
                            logger.info(f"Caption for {result.get('file_name', 'Unknown')}: {caption_text}")
            
            # Generate enhanced answer using GPT-4
            if answers_found or search_results:
                enhanced_answer = self.generate_enhanced_answer(query, search_results, answers_found)
                if enhanced_answer:
                    print(f"   🤖 GPT-4 ENHANCED ANSWER:")
                    print(f"   {enhanced_answer}")
                    logger.info(f"GPT-4 Enhanced Answer: {enhanced_answer}")
                    
                    # Update search summary for later display
                    self._update_search_summary(query, search_results, answers_found, enhanced_answer, index_type)
            
            print(f"   ✓ Semantic search works - {result_count} total results, {len(answers_found)} answers")
            if answers_found:
                logger.info(f"Total semantic answers extracted: {len(answers_found)}")
            return True
            
        except Exception as e:
            print(f"   ❌ Semantic search failed: {e}")
            log_http_error_details(e, "semantic", query)
            logger.error(f"Semantic search error: {e}")
            logger.debug(traceback.format_exc())
            return False
    
    def test_semantic_search_with_filters(self, query: str, index_type: str = "group") -> bool:
        """Test semantic search with proper filters like the successful log example."""
        print(f"\n🔍 Testing semantic search with filters: '{query}' on {index_type} index")
        
        try:
            client = self.user_search_client if index_type == "user" else self.group_search_client
            semantic_config = "nexus-user-index-semantic-configuration" if index_type == "user" else "nexus-group-index-semantic-configuration"
            
            # Use proper field selection like in the successful log
            select_fields = [
                "id", "chunk_text", "chunk_id", "file_name", "group_id", "version", 
                "chunk_sequence", "upload_date", "document_classification", 
                "page_number", "author", "chunk_keywords", "title", "chunk_summary"
            ]
            
            # For demo purposes, we'll search without specific filters first
            results = client.search(
                search_text=query,
                query_type="semantic",
                semantic_configuration_name=semantic_config,
                query_caption="extractive",
                query_answer="extractive",
                select=select_fields,
                search_mode="any",
                top=5
            )
            
            result_count = 0
            answers_found = []
            search_results = []
            
            # Extract semantic answers if available
            if hasattr(results, 'get_answers') and callable(results.get_answers):
                try:
                    semantic_answers = results.get_answers()
                    if semantic_answers:
                        print(f"   📝 SEMANTIC ANSWERS FOUND:")
                        for i, answer in enumerate(semantic_answers):
                            answer_text = answer.text if hasattr(answer, 'text') else str(answer)
                            print(f"   {i+1}. {answer_text}")
                            logger.info(f"Semantic Answer {i+1}: {answer_text}")
                            answers_found.append(answer_text)
                except Exception as e:
                    logger.debug(f"Could not extract answers: {e}")
            
            for result in results:
                # Store the raw result with Azure's score format for GPT enhancement
                actual_score = result.get('@search.score', 0)
                logger.debug(f"Raw filtered search result: file='{result.get('file_name', 'Unknown')}', score={actual_score} (type: {type(actual_score)})")
                
                search_results.append({
                    'file_name': result.get('file_name', 'Unknown'),
                    'chunk_text': result.get('chunk_text', ''),
                    'score': actual_score,  # Extract the actual search score
                    '@search.score': actual_score  # Keep both formats for compatibility
                })
                result_count += 1
                if result_count <= 3:  # Show first 3 results
                    group_id = result.get('group_id', 'N/A')
                    document_id = result.get('id', 'N/A')
                    print(f"   • {result.get('file_name', 'Unknown')} (GroupID: {group_id})")
                    print(f"     DocID: {document_id}")
                    
                    # Check for captions in the result
                    if '@search.captions' in result:
                        captions = result['@search.captions']
                        if captions:
                            caption_text = captions[0].text if hasattr(captions[0], 'text') else str(captions[0])
                            print(f"     Caption: {caption_text}")
                            logger.info(f"Caption for {result.get('file_name', 'Unknown')}: {caption_text}")
            
            # Generate enhanced answer using GPT-4
            if answers_found or search_results:
                enhanced_answer = self.generate_enhanced_answer(query, search_results, answers_found)
                if enhanced_answer:
                    print(f"   🤖 GPT-4 ENHANCED ANSWER:")
                    print(f"   {enhanced_answer}")
                    logger.info(f"GPT-4 Enhanced Answer: {enhanced_answer}")
                    
                    # Update search summary for later display
                    self._update_search_summary(query, search_results, answers_found, enhanced_answer, index_type)
            
            print(f"   ✓ Semantic search with proper fields works - {result_count} total results, {len(answers_found)} answers")
            if answers_found:
                logger.info(f"Total semantic answers extracted: {len(answers_found)}")
            return True
            
        except Exception as e:
            print(f"   ❌ Semantic search with filters failed: {e}")
            logger.error(f"Semantic search with filters error: {e}")
            logger.debug(traceback.format_exc())
            return False
    
    def test_hybrid_search_basic(self, query: str, index_type: str = "user") -> bool:
        """Test basic hybrid search (text + vector) without semantic features."""
        if not self.has_openai:
            print(f"\n⏭️  Skipping hybrid search: '{query}' (OpenAI not available)")
            return False
            
        print(f"\n🔍 Testing hybrid search (basic): '{query}' on {index_type} index")
        
        try:
            # Generate embedding
            embedding = self.generate_embedding(query)
            if not embedding:
                return False
            
            client = self.user_search_client if index_type == "user" else self.group_search_client
            
            vector_query = VectorizedQuery(
                vector=embedding,
                k_nearest_neighbors=5,
                fields="embedding"
            )
            
            results = client.search(
                search_text=query,
                vector_queries=[vector_query],
                top=5
            )
            
            result_count = 0
            for result in results:
                result_count += 1
                if result_count <= 3:  # Show first 3 results
                    # Safe formatting for score - handle potential 'N/A' or None values
                    score = result.get('@search.score', 'N/A')
                    if isinstance(score, (int, float)):
                        score_str = f"{score:.3f}"
                    else:
                        score_str = str(score)
                    print(f"   • {result.get('file_name', 'Unknown')} (Score: {score_str})")
            
            print(f"   ✓ Basic hybrid search works - {result_count} total results")
            return True
            
        except HttpResponseError as e:
            log_http_error_details(e, "hybrid", query)
            print(f"   ❌ Basic hybrid search failed: {e}")
            return False
        except Exception as e:
            print(f"   ❌ Basic hybrid search failed: {e}")
            logger.error(f"Hybrid search error: {e}")
            logger.debug(traceback.format_exc())
            return False
    
    def test_hybrid_semantic_search(self, query: str, index_type: str = "user") -> bool:
        """Test advanced hybrid semantic search (vector + text + semantic re-ranking)."""
        if not self.has_openai:
            print(f"\n⏭️  Skipping hybrid semantic search: '{query}' (OpenAI not available)")
            return False
            
        print(f"\n🚀 Testing hybrid semantic search (ADVANCED): '{query}' on {index_type} index")
        print("   🔄 Combining: Vector embeddings + Text search + Semantic re-ranking")
        
        try:
            # Generate embedding for vector component
            embedding_start = datetime.now()
            embedding = self.generate_embedding(query)
            embedding_time = (datetime.now() - embedding_start).total_seconds() * 1000
            
            if not embedding:
                print("   ❌ Failed to generate embedding for hybrid semantic search")
                return False
            
            client = self.user_search_client if index_type == "user" else self.group_search_client
            semantic_config = "nexus-user-index-semantic-configuration" if index_type == "user" else "nexus-group-index-semantic-configuration"
            
            # Create vector query component
            vector_query = VectorizedQuery(
                vector=embedding,
                k_nearest_neighbors=5,
                fields="embedding"
            )
            
            # Execute hybrid semantic search with all three components
            search_start = datetime.now()
            results = client.search(
                search_text=query,                          # Text search component
                vector_queries=[vector_query],              # Vector search component  
                query_type="semantic",                      # Semantic re-ranking
                semantic_configuration_name=semantic_config,
                query_caption="extractive",                 # Extract highlighted snippets
                query_answer="extractive",                  # Extract direct answers
                top=10,                                     # Get more results for better re-ranking
                search_mode="any"                          # Allow broader text matching
            )
            search_time = (datetime.now() - search_start).total_seconds() * 1000
            
            result_count = 0
            answers_found = []
            search_results = []
            
            # Extract semantic answers first (these are the best results from re-ranking)
            if hasattr(results, 'get_answers') and callable(results.get_answers):
                try:
                    semantic_answers = results.get_answers()
                    if semantic_answers:
                        print(f"   🎯 SEMANTIC ANSWERS (Re-ranked):")
                        for i, answer in enumerate(semantic_answers):
                            answer_text = answer.text if hasattr(answer, 'text') else str(answer)
                            print(f"   {i+1}. {answer_text}")
                            logger.info(f"Hybrid Semantic Answer {i+1}: {answer_text}")
                            answers_found.append(answer_text)
                except Exception as e:
                    logger.debug(f"Could not extract semantic answers: {e}")
            
            # Process search results (these are re-ranked by semantic relevance)
            print(f"   📊 HYBRID SEMANTIC RESULTS (Re-ranked by Semantic AI):")
            reranked_results = []
            for result in results:
                result_count += 1
                score = result.get('@search.score', 0)
                reranker_score = result.get('@search.reranker_score', 'N/A')
                file_name = result.get('file_name', 'Unknown')
                
                # Store result for GPT enhancement
                search_results.append({
                    'file_name': file_name,
                    'chunk_text': result.get('chunk_text', ''),
                    'score': score,
                    'reranker_score': reranker_score
                })
                
                # Track reranker impact - ensure we have valid numeric values
                if (reranker_score != 'N/A' and reranker_score is not None and 
                    isinstance(reranker_score, (int, float)) and isinstance(score, (int, float))):
                    reranked_results.append((file_name, score, reranker_score))
                
                if result_count <= 5:  # Show top 5 results
                    if (reranker_score != 'N/A' and reranker_score is not None and 
                        isinstance(reranker_score, (int, float)) and isinstance(score, (int, float))):
                        # Show dramatic re-ranking impact
                        rerank_change = "🚀 BOOSTED" if reranker_score > score else "📉 reduced"
                        print(f"   {result_count}. {file_name}")
                        print(f"      Original Score: {score:.3f} → Reranker Score: {reranker_score:.3f} ({rerank_change})")
                    else:
                        # Safe formatting for score - handle potential non-numeric values
                        if isinstance(score, (int, float)):
                            score_str = f"{score:.3f}"
                        else:
                            score_str = str(score)
                        print(f"   {result_count}. {file_name} (Score: {score_str})")
                    
                    # Show caption if available (semantic highlighting)
                    captions = result.get('@search.captions')
                    if captions:
                        for caption in captions[:1]:  # Show first caption
                            caption_text = caption.text if hasattr(caption, 'text') else str(caption)
                            print(f"      💡 Semantic Highlight: {caption_text[:150]}...")
            
            # Show re-ranking impact summary
            if reranked_results:
                print(f"   🎯 RE-RANKING IMPACT:")
                for i, (fname, orig, rerank) in enumerate(reranked_results[:3], 1):
                    # Ensure we have valid numeric values for calculation
                    if isinstance(orig, (int, float)) and isinstance(rerank, (int, float)) and orig > 0:
                        impact = ((rerank - orig) / orig * 100)
                        direction = "↗️ improved" if impact > 0 else "↘️ reduced"
                        print(f"      {i}. {fname}: {impact:+.1f}% {direction}")
                    else:
                        print(f"      {i}. {fname}: Unable to calculate impact (invalid scores)")
            
            # Generate enhanced answer using GPT with all the re-ranked results
            if self.has_openai and search_results:
                enhanced_answer = self.generate_enhanced_answer(query, search_results, answers_found)
                if enhanced_answer:
                    print(f"\n   🤖 GPT-Enhanced Answer:")
                    print(f"   {enhanced_answer}")
                
                # Update search summary
                self._update_search_summary(query, search_results, answers_found, enhanced_answer or "", index_type)
            
            print(f"   ✅ Hybrid semantic search completed - {result_count} results")
            print(f"   ⚡ Performance: Embedding {embedding_time:.0f}ms, Search {search_time:.0f}ms")
            print(f"   🎯 Semantic answers: {len(answers_found)}, Enhanced: {'Yes' if self.has_openai else 'No'}")
            
            return True
            
        except HttpResponseError as e:
            log_http_error_details(e, "hybrid semantic", query)
            print(f"   ❌ Hybrid semantic search failed: {e}")
            return False
        except Exception as e:
            print(f"   ❌ Hybrid semantic search failed: {e}")
            logger.error(f"Hybrid semantic search error: {e}")
            logger.debug(traceback.format_exc())
            return False
    
    def run_all_tests(self, query: str = "artificial intelligence") -> Dict[str, bool]:
        """Run all search tests."""
        print("=" * 60)
        print("SIMPLE AZURE AI SEARCH TEST")
        print("=" * 60)
        print(f"Search Endpoint: {self.search_endpoint}")
        print(f"OpenAI Available: {'Yes' if self.has_openai else 'No'}")
        print(f"Test Query: '{query}'")
        print()
        
        results = {}
        
        # Test basic text searches
        results['basic_user'] = self.test_basic_search(query, "user")
        results['basic_group'] = self.test_basic_search(query, "group")
        
        # Test semantic searches
        results['semantic_user'] = self.test_semantic_search(query, "user")
        results['semantic_group'] = self.test_semantic_search(query, "group")
        
        # Test semantic search with proper field selection (like successful log)
        results['semantic_filtered_group'] = self.test_semantic_search_with_filters(query, "group")
        
        # Test hybrid searches (only if OpenAI available)
        if self.has_openai:
            results['hybrid_basic_user'] = self.test_hybrid_search_basic(query, "user")
            results['hybrid_basic_group'] = self.test_hybrid_search_basic(query, "group")
            
            # Test advanced hybrid semantic search (the ultimate search method)
            results['hybrid_semantic_user'] = self.test_hybrid_semantic_search(query, "user")
            results['hybrid_semantic_group'] = self.test_hybrid_semantic_search(query, "group")
        
        # Summary
        print("\n" + "=" * 60)
        print("TEST SUMMARY")
        print("=" * 60)
        
        for test_name, success in results.items():
            status = "✓ PASS" if success else "❌ FAIL"
            print(f"{test_name:25} {status}")
        
        # Enhanced Diagnosis with HTTP Analysis
        print(f"\n🎯 DIAGNOSIS:")
        if results.get('hybrid_semantic_user') or results.get('hybrid_semantic_group'):
            print("🚀 Advanced hybrid semantic search works! (Vector + Text + Semantic Re-ranking)")
            print("💡 This is the most sophisticated search method available")
        elif results.get('hybrid_basic_user') or results.get('hybrid_basic_group'):
            print("✅ Basic hybrid search works! (Vector + Text)")
            print("💡 Consider enabling semantic configuration for advanced re-ranking")
        elif results.get('semantic_filtered_group'):
            print("✅ Semantic search with proper field selection works!")
            print("💡 Your log shows semantic search succeeds with specific filters and field selection")
        elif results['semantic_user'] or results['semantic_group']:
            print("⚠️  Basic semantic search works, but filtered semantic might have issues")
        elif results['basic_user'] or results['basic_group']:
            print("✅ Basic text search works")
            if not self.has_openai:
                print("ℹ️  Add OpenAI credentials to test hybrid and hybrid semantic search")
        else:
            print("❌ All searches failed - check configuration")
        
        # Search Results Summary
        if self.search_summary['query']:
            print(f"\n🎯 SEARCH RESULTS SUMMARY:")
            print("=" * 40)
            print(f"📋 Question Asked: '{self.search_summary['query']}'")
            
            if self.search_summary['highest_scoring_source']:
                print(f"🏆 Highest Scoring Result: {self.search_summary['highest_scoring_source']}")
            
            if self.search_summary['best_results']:
                print(f"📊 Top Results Found:")
                for i, result in enumerate(self.search_summary['best_results'], 1):
                    score_str = f"{result['score']:.3f}" if isinstance(result['score'], (int, float)) else str(result['score'])
                    print(f"   {i}. {result['file_name']} (Score: {score_str}, {result['index']} index)")
            
            if self.search_summary['semantic_answers']:
                print(f"🔍 Semantic Answers Found ({len(self.search_summary['semantic_answers'])}):")
                for i, answer in enumerate(self.search_summary['semantic_answers'], 1):
                    # Truncate long answers for summary
                    display_answer = answer[:100] + "..." if len(answer) > 100 else answer
                    print(f"   {i}. {display_answer}")
            
            if self.search_summary['enhanced_answer']:
                print(f"🤖 Final Enhanced Answer:")
                print(f"   {self.search_summary['enhanced_answer']}")
        
        return results


def main():
    """Main function - reads from environment variables or script settings."""
    
    # Starting diagnostic tool
    print("🔬 Starting Azure AI Search Diagnostic Tool...")
    print()
    
    # Try to get from environment variables first
    search_endpoint = os.getenv("AZURE_AI_SEARCH_ENDPOINT")
    search_key = os.getenv("AZURE_AI_SEARCH_KEY") 
    
    # Try multiple OpenAI environment variable names
    openai_endpoint = (
        os.getenv("AZURE_OPENAI_EMBEDDING_ENDPOINT") or 
        os.getenv("AZURE_OPENAI_ENDPOINT")
    )
    openai_key = (
        os.getenv("AZURE_OPENAI_EMBEDDING_KEY") or 
        os.getenv("AZURE_OPENAI_KEY")
    )
    
    # If not in environment, set them here
    if not search_endpoint:
        search_endpoint = "https://your-search-service.search.windows.net"
    if not search_key:
        search_key = "your-search-admin-key"
    if not openai_endpoint:
        openai_endpoint = "https://your-openai.openai.azure.com"
    if not openai_key:
        openai_key = "your-openai-key"
    
    # Validation
    if "your-search-service" in search_endpoint:
        print("❌ Please set AZURE_AI_SEARCH_ENDPOINT environment variable or edit the script")
        print("   Example: https://mysearch.search.windows.net")
        return
    
    if "your-search-admin-key" in search_key:
        print("❌ Please set AZURE_AI_SEARCH_KEY environment variable or edit the script")
        return
    
    # OpenAI is optional - clear invalid values
    if openai_endpoint and "your-openai" in openai_endpoint:
        openai_endpoint = None
    if openai_key and "your-openai" in openai_key:
        openai_key = None
    
    # Show configuration help if OpenAI isn't configured
    if not openai_endpoint or not openai_key:
        print("💡 For full hybrid search testing, set these environment variables:")
        print("   export AZURE_OPENAI_ENDPOINT='https://your-openai.openai.azure.com'")
        print("   export AZURE_OPENAI_KEY='your-openai-key'")
        print("   (or use AZURE_OPENAI_EMBEDDING_ENDPOINT and AZURE_OPENAI_EMBEDDING_KEY)")
        print("   Optional: AZURE_OPENAI_COMPLETION_DEPLOYMENT='gpt-4o'")
        print("   Optional: AZURE_OPENAI_EMBEDDING_DEPLOYMENT='text-embedding-ada-002'")
        print("")
    
    print(f"🔧 Configuration:")
    print(f"   Search Endpoint: {search_endpoint}")
    print(f"   OpenAI Endpoint: {openai_endpoint or 'Not set (text search only)'}")
    if openai_endpoint and openai_key:
        completion_deployment = os.getenv("AZURE_OPENAI_COMPLETION_DEPLOYMENT", "gpt-4o")
        embedding_deployment = os.getenv("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-ada-002")
        print(f"   GPT Completion Model: {completion_deployment}")
        print(f"   Embedding Model: {embedding_deployment}")
    print(f"   Log Level: {log_level}")
    print()
    
    # Run the tests
    tester = SimpleSearchTest(search_endpoint, search_key, openai_endpoint, openai_key)
    
    # Get test query from environment variable or use default
    test_query = os.getenv("TEST_QUERY", "what did Ahmed have for lunch")
    print(f"   Test Query: '{test_query}'")
    print()
    
    results = tester.run_all_tests(test_query)


if __name__ == "__main__":
    main()
